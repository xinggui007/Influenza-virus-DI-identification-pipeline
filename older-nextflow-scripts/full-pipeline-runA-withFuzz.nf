#!/usr/bin/env nextflow
/*
* USAGE: nextflow run myscript.nf -qs 8
* Note that "-qs" is similar to "#SLURM --array=##%8" and will only run a specified # of jobs at a time.
* This script creates hard links to data that exists in nextflows work directory.
*/

/*
 * Set parameter values here. Only change the values within quotations
 * Many of the values already present will be okay to use, but make sure the pathes
 * are correct for your dataset.
*/

/*Path to project folder*/
projectPath = "/home/groups/hpcbio_shared/cbrooke_lab/DARPA-project/"

/* Paths to bowtie indices */
bowtie2_index = "${projectPath}/data/genome/bowtie2-2.3.2-index/modified_PR8"
virema_index = "${projectPath}/data/genome/bowtie-1.2.0-index/modified_PR8_ref_padded"

viremaApp = "${projectPath}/apps/ViReMa_with_Fuzz"

/* Path to raw fastq files */
rawDataPath = "${projectPath}/data/raw-seq/5_samples"
Channel
    .fromFilePairs("${rawDataPath}/*_R{1,2}_001.fastq", flat: true)
    .ifEmpty {error "Cannot find any reads matching: ${params.reads}"}
    .set {reads}

/*Biocluster options. List memory in gigabytes like in suggestions below*/
myQueue = 'normal'
trimMemory = '15'
trimCPU = '6'
bowtie2Mem = '15'
bowtie2CPU = '6'
viremaMem = '60'
viremaCPU = '6'


/*Module versions*/
trimMod = 'Trimmomatic/0.36-Java-1.8.0_121'
trimVersion = '0.36' /*Put the version here only*/
fastqcMod = 'FastQC/0.11.5-IGB-gcc-4.9.4-Java-1.8.0_121'
bowtie2Mod = 'Bowtie2/2.3.2-IGB-gcc-4.9.4'
bowtie1Mod = 'Bowtie/1.2.0-IGB-gcc-4.9.4'
pythonMod = 'Python/2.7.13-IGB-gcc-4.9.4'
perlMod = 'Perl/5.24.1-IGB-gcc-4.9.4'

/*
* Trimming options. Change trimming options here and note that $trimVersion is used to make sure
* the version is called consistently.
*/
trimOptions = 'ILLUMINACLIP:$EBROOTTRIMMOMATIC/adapters/TruSeq3-PE-2.fa:2:15:10 SLIDINGWINDOW:3:20 LEADING:28 TRAILING:28 MINLEN:75'

/* Alignment & Counting options */
scoreMin = 'L,0,-0.3' /* This is the value for --score-min */
micro = '20' /* The minimum length of microindels */
defuzz = '3' /* If a start position is fuzzy, then its reported it at the 3' end (3), 5' end (5), or the center of fuzzy region (0). */
mismatch = '0' /* This is the value of --N in ViReMa */

/*Output paths*/
trimPath = "${projectPath}/results/Mar2017-Fuzz-runA/trimmomatic"
fastqcPath = "${projectPath}/results/Mar2017-Fuzz-runA/fastqc_trim"
alignPath = "${projectPath}/results/Mar2017-Fuzz-runA/bowtie2"
viremaPath = "${projectPath}/results/Mar2017-Fuzz-runA/virema"


/*
* Step 1. Trimming
* WARNING: considers '1' a valid exit status to get around wrapper error
*/

process trimmomatic {
    executor 'slurm'
    cpus trimCPU
    queue myQueue
    memory "$trimMemory GB"
    module trimMod
    publishDir trimPath, mode: 'link'
    validExitStatus 0,1

    input:
    set val(id), file(read1), file(read2) from reads

    output:
    set val(id), "${read1.baseName}.qualtrim.paired.fastq", "${read2.baseName}.qualtrim.paired.fastq" into fastqChannel
    set val(id), "${read1.baseName}.qualtrim.paired.fastq", "${read2.baseName}.qualtrim.paired.fastq" into catChannel
    file "*.qualtrim.unpaired.fastq"
    stdout trim_out

    """
    java -jar \$EBROOTTRIMMOMATIC/trimmomatic-${trimVersion}.jar PE \
    -threads $trimCPU -phred33 $read1 $read2 \
    ${read1.baseName}.qualtrim.paired.fastq ${read1.baseName}.qualtrim.unpaired.fastq \
    ${read2.baseName}.qualtrim.paired.fastq ${read2.baseName}.qualtrim.unpaired.fastq $trimOptions
    """
}


/*
* Step 2. FASTQC of trimmed reads
*/
process runFASTQC {
    executor 'slurm'
    cpus 1
    queue myQueue
    memory '2 GB'
    module fastqcMod
    publishDir fastqcPath, mode: 'link'

    input:
    set pair_id, file(read1), file(read2) from fastqChannel

    output:
    file "*.html"
    file "*.zip"

    """
    fastqc -o ./ --noextract $read1
    fastqc -o ./ --noextract $read2
    """
}

/*
* Step 3. Combine FASTQ pairs
*/
process combineFASTQ {
    executor 'slurm'
    queue myQueue
    publishDir trimPath, mode: 'link'

    input:
    set pair_id, file(read1), file(read2) from catChannel

    output:
    file  "*both.fq" into bowtie2_channel

    """
    cat $read1 $read2 > ${pair_id}both.fq
    """
}

/*
* Step 4. Bowtie2 alignment
*/
process runbowtie2 {
    executor 'slurm'
    cpus bowtie2CPU
    queue myQueue
    memory "$bowtie2Mem GB"
    module bowtie2Mod
    publishDir alignPath, mode: 'link'

    input:
    file in_cat from bowtie2_channel

    output:
        file "*_unaligned.fq" into virema_channel
        file "*.sam"
        file "*_aligned.fq"

    """
    bowtie2 -p $bowtie2CPU -x $bowtie2_index -U $in_cat --score-min $scoreMin \
    --al ${in_cat.baseName}_aligned.fq --un ${in_cat.baseName}_unaligned.fq > ${in_cat.baseName}.sam

    """
}

/*
* Step 5. ViReMa
*/
process runVirema {
    executor 'slurm'
    cpus viremaCPU
    queue myQueue
    memory "$viremaMem GB"
    module "${bowtie1Mod}:${pythonMod}"
    publishDir viremaPath, mode: 'link'

    input:
    file unalign from virema_channel

    output:
    file "*.results"
    file "*Virus_Recombination_Results.txt" into virema_sum
    file "*tions.txt"
    file "*UnMapped*.txt"
    file "*Single*.txt"
    file "*_rename.fq"

    """
    awk '{print (NR%4 == 1) ? "@1_" ++i : \$0}' $unalign >  ${unalign.baseName}_rename.fq
    
    python ${viremaApp}/ViReMa.py --MicroInDel_Length $micro -DeDup --Defuzz $defuzz \
    --N $mismatch --Output_Tag $unalign.baseName -ReadNamesEntry --p $viremaCPU \
    $virema_index ${unalign.baseName}_rename.fq ${unalign.baseName}.results

    """
}

/*
* Step 6. ViReMa Summary of results (w/ perl scripts)
*/
process runSummary {
    executor 'slurm'
    queue myQueue
    memory "$viremaMem GB"
    module perlMod
    publishDir viremaPath, mode: 'link'

    input:
    file in_file from virema_sum

    output:
    file "*.par5*"

    """
    perl ${projectPath}/src/Brooke-DARPA/parse-recomb-results-5.pl $in_file ${in_file.baseName}.par5
    """
}
