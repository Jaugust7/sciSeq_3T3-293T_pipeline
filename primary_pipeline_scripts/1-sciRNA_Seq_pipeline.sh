#!/bin/bash
# this scRNA-seq pipeline accept a input folder, and then use the default parameter for the data processing and analysis, and generate a sparse gene count matrix for downstream analysis

#SBATCH
#SBATCH --job-name=3T3_293T_sciRNAseq_pipeline
#SBATCH --time=4:00:00
#SBATCH --partition=shared
# number of cpus (threads) per task (process)
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=60000
#SBATCH --mail-type=end
#SBATCH --mail-user=jaugust7@jhu.edu

fastq_folder=/home-2/jaugust7@jhu.edu/work/seq/Jaugustin/3T3_293T_sciSeq_test/3T3_293T-Demux/sciRNA_test # the folder for fastq files
all_output_folder=/home-2/jaugust7@jhu.edu/work/seq/Jaugustin/3T3_293T_sciSeq_test/3T3_293T-Demux # the output folder
sample_ID=/home-2/jaugust7@jhu.edu/work/seq/Jaugustin/3T3_293T_sciSeq_test/scripts/sample_IDs.txt # the sample ID for each PCR samples after demultiplex (this should just be the sample name without read info i.e "3T3_293T_PA1_A01")
gtf_file=/home-2/jaugust7@jhu.edu/work/assemblies/xspecies/hg19-mm10/JJA/hg19-mm10_gencode_xspecies.gtf
core=12 # core number for computation
cutoff=1000  # the number of unique reads cutoff for splitting single cells
barcodes=/home-2/jaugust7@jhu.edu/work/seq/Jaugustin/3T3_293T_sciSeq_test/scripts/Oligo_dT_barcodes.txt # the RT barcode list for splitting single cells
index=/home-2/jaugust7@jhu.edu/work/indexes/xspecies/hg19-mm10/STAR
script_folder=/home-2/jaugust7@jhu.edu/work/users/Jaugustin/sciRNA_pipeline/primary_pipeline_scripts # the script folder for called python scripts

#define the mismatch rate (edit distance) of UMIs for removing duplicates:

mismatch=1

#define the bin of python
python_path="/usr/bin/env"

#define the location of script:
script_path=$script_folder

#module load samtools (these are already loaded in my environment)
#module load bedtools

############ RT barcode and UMI attach
# this script take in a input folder, a sample ID, a output folder, a oligo-dT barcode file and
# call the python script to extract the UMI and RT barcode from read1 and attach them to the read names of read2
input_folder=$fastq_folder
output_folder=$all_output_folder/UMI_attach
script=$script_folder/UMI_barcode_attach_gzipped.py
echo "changing the name of the fastq files..."

for sample in $(cat $sample_ID); do echo changing name $sample; mv $input_folder/$sample*R1*gz $input_folder/$sample.R1.fastq.gz; mv $input_folder/$sample*R2*gz $input_folder/$sample.R2.fastq.gz; done

echo "Attaching barcode and UMI...."
mkdir -p $output_folder
$python_path python $script $input_folder $sample_ID $output_folder $barcodes $core
echo "Barcode transformed and UMI attached."

################# Trim the read2
echo
echo "Start trimming the read2 file..."
echo $(date)
#module load python
#module load cutadapt (these are already loaded in my environmnet)
module load trim_galore
module load gnu-parallel

mkdir $all_output_folder/trimmed_fastq
trimmed_fastq=$all_output_folder/trimmed_fastq
UMI_attached_R2=$all_output_folder/UMI_attach
for sample in $(cat $sample_ID); do echo trimming $sample; sem -j $core trim_galore $UMI_attached_R2/$sample*.gz -a AAAAAAAA --three_prime_clip_R1 1 -o $trimmed_fastq; done
sem --semaphoretimeout 1800
echo "All trimmed file generated."
#module unload python/2.7.3

############align the reads with STAR, filter the reads, and remove duplicates based on UMI sequence and tagmentation site

#define the output folder
input_folder=$trimmed_fastq
STAR_output_folder=$all_output_folder/STAR_alignment
filtered_sam_folder=$all_output_folder/filtered_sam
rmdup_sam_folder=$all_output_folder/rmdup_sam

#align read2 to the index file using STAR with default setting
echo "Start alignment using STAR..."
echo input folder: $input_folder
echo sample ID file: $sample_ID
echo index file: $index
echo output_folder: $STAR_output_folder
module load star
#make the output folder
mkdir -p $STAR_output_folder
#remove the index from the memory
#STAR --genomeDir $index --genomeLoad Remove
#start the alignment
for sample in $(cat $sample_ID); do echo Aligning $sample;STAR --runThreadN $core --outSAMstrandField intronMotif --genomeDir $index --readFilesCommand zcat --readFilesIn $input_folder/$sample*gz --outFileNamePrefix $STAR_output_folder/$sample --genomeLoad NoSharedMemory ; done
#remove the index from the memory
#STAR --genomeDir $index --genomeLoad Remove
echo "All alignment done."

# filter and sort the sam file
echo
echo "Start filter and sort the sam files..."
echo input folder: $STAR_output_folder
echo output folder: $filtered_sam_folder
mkdir -p $filtered_sam_folder
module load samtools
module load gnu-parallel
for sample in $(cat $sample_ID); do echo Filtering $sample; sem -j $core samtools view -bh -q 30 -F 4 $STAR_output_folder/$sample*.sam|samtools sort|samtools view -h ->$filtered_sam_folder/$sample.sam; done
sem --semaphoretimeout 1800

# Then for each filtered sam file, remove the duplicates based on UMI and barcode, chromatin number and position
echo
echo "Start removing duplicates..."
echo input folder: $filtered_sam_folder
echo output folder: $rmdup_sam_folder
mkdir -p $rmdup_sam_folder
#module unload python
module load gnu-parallel
for sample in $(cat $sample_ID); do echo remove duplicate $sample;sem -j $core $python_path python $script_path/rm_dup_barcode_UMI.py $filtered_sam_folder/$sample.sam $rmdup_sam_folder/$sample.sam $mismatch; done 
sem --semaphoretimeout 1800

#mv the reported files to the report/duplicate_read/ folder
mkdir -p $input_folder/../report/duplicate_read
mv $rmdup_sam_folder/*.csv $input_folder/../report/duplicate_read/
mv $rmdup_sam_folder/*.png $input_folder/../report/duplicate_read/
echo "removing duplicates completed.."
echo
echo "Alignment and sam file preprocessing are done."  

################# split the sam file based on the barcode, and mv the result to the report folder
sam_folder=$all_output_folder/rmdup_sam
#bash $script_folder/samfile_split_multi_threads.sh $sam_folder $sample_ID $out_folder $barcodes $cutoff This file doesn't exist and seems to have been replaced with a python equivalent...
sample_list=$sample_ID
output_folder=$all_output_folder/sam_splitted
barcode_file=$barcodes
cutoff=$cutoff

echo
echo "Start splitting the sam file..."
echo samfile folder: $sam_folder
echo sample list: $sample_list
echo ouput folder: $output_folder
echo barcode file: $barcode_file
echo cutoff value: $cutoff
mkdir -p $output_folder
#module unload python
module load gnu-parallel
for sample in $(cat $sample_list); do echo Now splitting $sample; sem -j $core $python_path python $script_path/sam_split.py $sam_folder/$sample.sam $barcode_file $output_folder $cutoff; done
sem --semaphoretimeout 1800
cat $output_folder/*.tab>$output_folder/All_samples_UMIs.txt
cp $output_folder/All_samples_UMIs.txt $output_folder/../sample_UMIs.txt
cat $output_folder/*sample_list.txt>$output_folder/All_samples.txt
cp $output_folder/All_samples.txt $output_folder/../barcode_samples.txt
# output the report the report/barcode_read_distribution folder
mkdir -p $output_folder/../report/barcode_read_distribution
mv $output_folder/*.txt $output_folder/../report/barcode_read_distribution/
mv $output_folder/*.png $output_folder/../report/barcode_read_distribution/
echo
echo "All sam file splitted."

################### calculate the reads number

fastq_folder=$fastq_folder
trimmed_folder=$trimmed_fastq
UMI_attach=$UMI_attached_R2
alignment=$STAR_output_folder
filtered_sam=$filtered_sam_folder
rm_dup_sam=$rmdup_sam_folder
#split_sam=$parental_folder/splited_sam
report_folder=$all_output_folder/report/read_num
echo
echo "Start calculating the reads number..."
#make the report folder
mkdir -p $report_folder
#calculate the read number and output the read number into the report folder
echo sample,total reads,after filtering barcode,after trimming,uniquely aligned reads,After remove duplicates>$report_folder/read_number.csv
for sample in $(cat $sample_ID); do echo calculating $sample; echo $sample,$(expr $(zcat $fastq_folder/$sample*R2*.gz|wc -l) / 4),$(expr $(zcat $UMI_attach/$sample*R2*.gz|wc -l) / 4),$(expr $(zcat $trimmed_folder/$sample*R2*.gz|wc -l) / 4),$(samtools view $filtered_sam/$sample.sam|wc -l),$(samtools view $rm_dup_sam/$sample.sam|wc -l)>>$report_folder/read_number.csv; done
echo "Read number calculation is done."

################## calculate the mouse and human and c.elegans reads fraction
input_folder=$all_output_folder/sam_splitted
sample_ID=$all_output_folder/barcode_samples.txt
output_folder=$all_output_folder/report/read_human_mouse
echo 
echo "Start calculating the mouse and human fraction..."
mkdir -p $output_folder
echo sample,human_reads,mouse_reads, cele_reads>$output_folder/human_mouse_fraction.txt
for sample in $(cat $sample_ID); do echo Processing $sample; echo $sample,$(samtools view $input_folder/$sample.sam|grep 'chr'|grep 'hg19' -v|wc -l),$(samtools view $input_folder/$sample.sam|grep 'chr'|grep 'mm10' -v|wc -l),$(samtools view $input_folder/$sample.sam|grep 'cele'|wc -l)>>$output_folder/human_mouse_fraction.txt; done
echo "Calculation done."

################# Generate the sparse gene count matrix
# count reads mapping to genes
output_folder=$all_output_folder/report/human_mouse_gene_count/
core_number=$core

script=$script_folder/sciRNAseq_count.py
module load python 
echo "Start the gene count...."
$python_path python $script $gtf_file $input_folder $sample_ID $core_number

echo "Make the output folder and transfer the files..."
mkdir -p $output_folder
cat $input_folder/*.count > $output_folder/count.MM
#rm $input_folder/*.count
cat $input_folder/*.report > $output_folder/report.MM
#rm $input_folder/*.report
mv $input_folder/*_annotate.txt $output_folder/
echo "All output files are transferred~"

echo "Analysis is done and gene count matrix is generated~"
