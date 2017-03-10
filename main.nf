/*
 * Copyright (c) 2017, Centre for Genomic Regulation (CRG).
 *
 *   This file is part of 'CalliNGS-NF': 
 *   A Nextflow pipeline for Variant Calling with NGS data
 *
 *   CalliNGS-NF is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   CalliNGS-NF is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with CalliNGS-NF.  If not, see <http://www.gnu.org/licenses/>.
 */
 
  
/* 
 * 'CalliNGS-NF' - A Nextflow pipeline for variant calling with NGS data
 * 
 * This pipeline that reproduces steps from the GATK best practics of SNP 
 * calling with RNAseq data procedure:
 * https://software.broadinstitute.org/gatk/guide/article?id=3891
 * 
 * Anna Vlasova 
 * Emilio Palumbo 
 * Paolo Di Tommaso
 * Evan Floden 
 */


/*
 * Define the default parameters
 */ 

params.genome     = "$baseDir/data/genome.fa"
params.variants   = "$baseDir/data/known_variants.vcf.gz"
params.blacklist  = "$baseDir/data/blacklist.bed" 
params.reads      = "$baseDir/data/reads/*_{1,2}.fastq.gz"
params.results    = "results"
params.gatk       = '/usr/local/bin/GenomeAnalysisTK.jar'

/*
 *  Parse the input parameters
 */

GATK            = params.gatk
genome_file     = file(params.genome)
variants_file   = file(params.variants)
blacklist_file  = file(params.blacklist)
reads_ch        = Channel.fromFilePairs(params.reads)


/**********
 * PART 1: Data preparation
 *
 * Process 1A: Create STAR genome index file.
 */

process '1A_prepare_star_genome_index' {

  input: 
      file(genome) from genome_file 

  output: 
      file(genome_dir) into genome_index_ch

  """
  mkdir genome_dir

  STAR --runMode genomeGenerate \
       --genomeDir genome_dir \
       --genomeFastaFiles ${genome} \
       --runThreadN ${task.cpus}
  """
}


/* 
 * Process 1B: Create a FASTA genome index (.fai) with samtools for GATK
 */

process '1B_prepare_genome_samtools' {
  
  input: 
      file genome from genome_file 
  
  output: 
      file "${genome}.fai" into genome_index  
  
  """
  samtools faidx ${genome}
  """
}


/*
 * Process 1C: Create a FASTA genome sequence dictionary with Picard for GATK  
 */

process '1C_prepare_genome_picard' {
 
  input: 
      file genome from genome_file 
  output: 
      file "${genome.baseName}.dict" into genome_dict
  
  """
  PICARD=`which picard.jar`
  java -jar -XX:ParallelGCThreads=8 \$PICARD CreateSequenceDictionary R= $genome O= ${genome.baseName}.dict
  """
}

/*
 * Process 1D: Create a file containing the filtered and recoded set of variants
 */


process '1D_prepare_vcf_file' {

  input: 
      file(variantsFile) from variants_file
      file(blacklisted) from blacklist_file

  output:
      set file("${variantsFile.baseName}.filtered.recode.vcf.gz"), file("${variantsFile.baseName}.filtered.recode.vcf.gz.tbi") into prepared_vcf
    
  """
  vcftools --gzvcf $variantsFile -c \
           --exclude-bed ${blacklisted} \
           --recode | bgzip -c \
           > ${variantsFile.baseName}.filtered.recode.vcf.gz

  tabix ${variantsFile.baseName}.filtered.recode.vcf.gz
  """
}

/*
 *  END OF PART 1
 *********/



/**********
 * PART 2: STAR RNA-Seq Mapping
 *
 * Process 2: Align RNA-Seq reads to the genome with STAR
 */

process '2_rnaseq_mapping_star' {

  input: 
      file genome from genome_file 
      file genomeDir from genome_index_ch
      set pairId, file(reads) from reads_ch 

  output: 
      set pairId, file('Aligned.sortedByCoord.out.bam'), file('Aligned.sortedByCoord.out.bam.bai') into output_groupFile

  """
  #ngs-nf-dev Align reads to genome
  STAR --genomeDir $genomeDir \
       --readFilesIn $reads \
       --runThreadN ${task.cpus} \
       --readFilesCommand zcat \
       --outFilterType BySJout \
       --alignSJoverhangMin 8 \
       --alignSJDBoverhangMin 1 \
       --outFilterMismatchNmax 999
    
  # 2nd pass (improve alignmnets using table of splice junctions and create a new index)  
  mkdir genomeDir  
  STAR --runMode genomeGenerate \
       --genomeDir genomeDir \
       --genomeFastaFiles $genome \
       --sjdbFileChrStartEnd SJ.out.tab \
       --sjdbOverhang 75 \
       --runThreadN ${task.cpus}  
    
  # Final read alignments  
  STAR --genomeDir genomeDir \
       --readFilesIn $reads \
       --runThreadN ${task.cpus} \
       --readFilesCommand zcat \
       --outFilterType BySJout \
       --alignSJoverhangMin 8 \
       --alignSJDBoverhangMin 1 \
       --outFilterMismatchNmax 999 \
       --outSAMtype BAM SortedByCoordinate \
       --outSAMattrRGline ID:$pairId LB:library PL:illumina PU:machine SM:GM12878

  # Index the BAM file
  samtools index Aligned.sortedByCoord.out.bam
  """
}

/*
 *  END OF PART 2
 ******/


/**********
 * PART 3: GATK Prepare Mapped Reads
 *
 * Process 3: Split reads that contain Ns in their CIGAR string.
 *            Creates k+1 new reads (where k is the number of N cigar elements) 
 *            that correspond to the segments of the original read beside/between 
 *            the splicing events represented by the Ns in the original CIGAR.
 */

process '3_rnaseq_gatk_splitNcigar' {

  input: 
      file genome from genome_file 
      file index from genome_index
      file genome_dict from genome_dict
      set pairId, file(bam), file(index) from output_groupFile

  output:
      set pairId, file('split.bam'), file('split.bai') into output_split
  
  """
  # SplitNCigarReads and reassign mapping qualities
  java -jar $GATK -T SplitNCigarReads \
                  -R $genome -I $bam \
                  -o split.bam \
                  -rf ReassignOneMappingQuality \
                  -RMQF 255 -RMQT 60 \
                  -U ALLOW_N_CIGAR_READS \
                  --fix_misencoded_quality_scores
  """
}

/*
 *  END OF PART 3
 ******/


/***********
 * PART 4: GATK Base Quality Score Recalibration Workflow
 *
 * Process 4: Base recalibrate to detect systematic errors in base quality scores, 
 *            select unique alignments and index
 *             
 */

process '4_rnaseq_gatk_recalibrate' {
  
  input: 
      file genome from genome_file 
      file index from genome_index
      file genome_dict from genome_dict
      set pairId, file(bam), file(index) from output_split
      set file(variants_file), file(variants_file_index) from prepared_vcf

  output:
      set replicateId, file("${pairId}.final.uniq.bam"), file("${pairId}.final.uniq.bam.bai") into (output_final, bam_for_ASE)
  
  script: 
  replicateId = pairId.replaceAll(/[12]$/,'')
  """
  # Indel Realignment and Base Recalibration
  java -jar $GATK -T BaseRecalibrator \
                  -nct 8 --default_platform illumina \
                  -cov ReadGroupCovariate \
                  -cov QualityScoreCovariate \
                  -cov CycleCovariate \
                  -knownSites ${variants_file} \
                  -cov ContextCovariate \
                  -R ${genome} -I ${bam} \
                  --downsampling_type NONE \
                  -o final.rnaseq.grp

  java -jar $GATK -T PrintReads \
                  -R ${genome} -I ${bam} \
                  -BQSR final.rnaseq.grp \
                  -o final.bam

  # Select only unique alignments, no multimaps
  (samtools view -H final.bam; samtools view final.bam| grep -w 'NH:i:1') \
  |samtools view -Sb -  > ${pairId}.final.uniq.bam

  # Index BAM files
  samtools index ${pairId}.final.uniq.bam
  """
}

/*
 *  END OF PART 4
 ******/



/***********
 * PART 5: GATK Variant Calling
 *
 * Process 5: Call variants with GATK HaplotypeCaller.
 *            Calls SNPs and indels simultaneously via local de-novo assembly of 
 *            haplotypes in an active region.
 *            Filter called variants with GATK VariantFiltration.    
 */


process '5_rnaseq_call_variants' {
  publishDir params.results

  input:
      file genome from genome_file
      file index from genome_index
      file genome_dict from genome_dict
      set replicateId, file(bam), file(index) from output_final.groupTuple()
  
  output: 
      set replicateId, file('*.final.vcf') into vcf_files

  """
  echo "${bam.join('\n')}" > bam.list
  
  # Variant calling
  java -jar $GATK -T HaplotypeCaller \
                  -R $genome -I bam.list \
                  -dontUseSoftClippedBases \
                  -stand_call_conf 20.0 \
                  -o output.gatk.vcf.gz

  # Variant filtering
  java -jar $GATK -T VariantFiltration \
                  -R $genome -V output.gatk.vcf.gz \
                  -window 35 -cluster 3 \
                  -filterName FS -filter "FS > 30.0" \
                  -filterName QD -filter "QD < 2.0" \
                  -o ${replicateId}.final.vcf
  """
}

/*
 *  END OF PART 5
 ******/


/***********
 * PART 6: Post-process variants file and prepare for Allele-Specific Expression and RNA Editing Analysis
 *
 * Process 6A: Post-process the VCF result  
 */

process '6A_post_process_vcf' {
  publishDir params.results
  
  input:
      set replicateId, file('final.vcf') from vcf_files
      set file('filtered.recode.vcf.gz'), file('filtered.recode.vcf.gz.tbi') from prepared_vcf
  
  output: 
      set replicateId, file('final.vcf'), file('result.commonSNPs.diff.sites_in_files') into vcf_and_snps_ch
  
  '''
  grep -v '#' final.vcf | awk '$7~/PASS/' |perl -ne 'chomp($_); ($dp)=$_=~/DP\\=(\\d+)\\;/; if($dp>=8){print $_."\\n"};' > result.DP8.vcf
  
  vcftools --vcf result.DP8.vcf --gzdiff filtered.recode.vcf.gz  --diff-site --out result.commonSNPs
  
  '''
}

/* 
 * Process 6B: Prepare variants file for allele specific expression (ASE) analysis
 */

process '6B_prepare_vcf_for_ase' {
  input: 
      set replicateId, file('final.vcf'), file('result.commonSNPs.diff.sites_in_files') from vcf_and_snps_ch

  output: 
      set replicateId, file('out.recode.vcf') into vcf_for_ASE

  '''
  awk 'BEGIN{OFS="\t"} $4~/B/{print $1,$2,$3}' result.commonSNPs.diff.sites_in_files  > test.bed
    
  vcftools --vcf  final.vcf --bed test.bed --recode --keep-INFO-all
  '''
}


/* 
 * Group data for allele-specific expression
 */

bam_for_ASE
  .groupTuple()
  .phase(vcf_for_ASE)
  .map{ left, right -> 
    def repId = left[0]
    def bam = left[1]
    def bai = left[2]
    def vcf = right[1]
    tuple(repId, vcf, bam, bai)  
  }
  .set { grouped_vcf_bam_bai }


/* 
 * Process 6C: Allele-Specific Expression analysis with GATK ASEReadCounter.
 *             Calculates allele counts at a set of positions after applying 
 *             filters that are tuned for enabling allele-specific expression 
 *             (ASE) analysis
 */

process '6C_ASE_knownSNPs' {
  publishDir params.results
  
  input:
  file genome from genome_file 
  file index from genome_index
  file dict from genome_dict
  set val(replicateId), file(vcf),  file(bam), file(bai) from grouped_vcf_bam_bai
  
  output:
  file 'ASER.out'
  
  """
  echo "${bam.join('\n')}" > bam.list
    
  java -jar $GATK -R ${genome} \
                  -T ASEReadCounter \
                  -o ASER.out \
                  -I bam.list \
                  -sites ${vcf}
  """
}

/*
 *  END OF PART 6
 ******/

