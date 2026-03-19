#!/bin/bash

# Define the log file name
LOG_FILE="pipeline_$(date +%Y%m%d_%H%M%S).log"

# Redirect stdout (1) and stderr (2) to the log file
# The 'tee' command allows you to see the output in the terminal AND save it to the file
exec > >(tee -a "$LOG_FILE") 2>&1


echo ""
show_help() {
cat << EOF
Usage: $(basename "$0") [OPTIONS]

DESCRIPTION:
    Automated pipeline for Nanopore 16S unclassified barcode recovery, BLAST validation, and NanoPlot quality control.

REQUIRED ARGUMENTS:
    -i, --input      <FILE>    Unclassified FASTQ file.
    -o, --output     <DIR>     Directory where results will be saved.
    -b, --barcodes   <FILE>    FASTA file containing the barcode sequences.
    -r, --reads_dir  <DIR>     Folder containing demultiplexed FASTQ files.

OPTIONAL ARGUMENTS:
    -w,        --word_size              <INT>     Word size for BLASTn (barcode length = 24) [Default: 11].
    -p,        --perc_identity          <INT>     Percent identity for BLASTn alignment (0-100) [Default: 0].
    -min,      --min_length             <INT>     Minimum read length to keep [Default: 0].
    -max,      --max_length             <INT>     Maximum read length to keep [Default: None].
    -nanoplot, --nanoplot_concatenated  <on|off>  Run NanoPlot for concatenated reads [Default: on].
    -t,        --threads                <INT>     Number of CPU threads to use [Default: 4].
    -h,        --help                             Display this help manual and exit.


EOF
}



CWD="$(pwd)"

# Initialize variables
INPUT_FILE=""
OUTPUT_DIR=""
BARCODE_FILE=""
WORD_SIZE=11
SQK_FOLDER=""
THREADS=4
PERC_IDENTITY=0
MIN_LENGTH=0
MAX_LENGTH=999999999 # Effectively no limit by default
RUN_NANOPLOT="on"

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -i|--input)
      INPUT_FILE="$2"
      shift 2 
      ;;
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -b|--barcodes)
      BARCODE_FILE="$2"
      shift 2
      ;;
    -w|--word_size)
      # Optional: Add validation to ensure it's a positive integer
      if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 4 ]; then
        WORD_SIZE="$2"
      else
        echo "Error: -word_size must be a at least 4."
        exit 1
      fi
      shift 2
      ;;
    -min|--min_length)
      MIN_LENGTH="$2"
      shift 2
      ;;
    -max|--max_length)
      MAX_LENGTH="$2"
      shift 2
      ;;
    -p|--percent_identity)
      # Basic validation to ensure it is a number
      if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -le 100 ]; then
        PERC_IDENTITY="$2"
      else
        echo "Error: -perc_identity must be an integer between 0 and 100."
        exit 1
      fi
      shift 2
      ;;
    -t|--threads)
      THREADS="$2"
      shift 2
      ;;
    -r|--reads_dir)
      if [[ -d "$2" ]]; then
        SQK_FOLDER="$(realpath "$2")"
      else
        echo "Error: Reads folder '$2' not found."
        exit 1
      fi
      shift 2
      ;;
    -nanoplot|--nanoplot_concatenated)
      if [[ "$2" == "off" ]]; then
        RUN_NANOPLOT="off"
      else
        RUN_NANOPLOT="on"
      fi
      shift 2
      ;;
    *)
      echo "Unknown argument: $1. Use -h for help."
      exit 1
      ;;
  esac
done 

# 2. Safety Check (Fixed variable check for SQK_FOLDER)
if [[ -z "$INPUT_FILE" || -z "$OUTPUT_DIR" || -z "$BARCODE_FILE" || -z "$SQK_FOLDER" ]]; then
    echo "Error: Missing required arguments."
    show_help
    exit 1
fi

# 3. Path Management
# 1. Setup absolute paths BEFORE entering the output dir
FULL_INPUT_PATH=$(realpath "$INPUT_FILE")
FULL_BARCODE_PATH=$(realpath "$BARCODE_FILE")

# This creates the filename but keeps it relative to where we are GOING
# e.g., "unclassified.fasta"
REL_FASTA_NAME="$(basename "${INPUT_FILE%.*}").fasta"

# 4. Processing
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR" || exit 1

# Define the WORK_FILE as an absolute path inside the new directory
WORK_FILE="$(pwd)/$REL_FASTA_NAME"

echo ""
echo "Running Pipeline..."
echo ""
seqkit fq2fa "$FULL_INPUT_PATH" > "$WORK_FILE"

echo "Total number of unclassified reads $(grep -c ">" "$WORK_FILE")"
echo ""

# 5. Size Filtering (Only runs if -min or -max are specified)
if [ "$MIN_LENGTH" -gt 0 ] || [ "$MAX_LENGTH" -lt 999999999 ]; then
    echo "--- Starting Size Filtering ---"
    echo "Target Range: $MIN_LENGTH to $MAX_LENGTH bp"
    
    mkdir -p filtered_out_reads

    # A. Capture reads that are too SHORT
    if [ "$MIN_LENGTH" -gt 0 ]; then
        seqkit seq -M $((MIN_LENGTH - 1)) "$WORK_FILE" > filtered_out_reads/lower_length_fail.fasta 2> /dev/null
        echo "  - Identified short reads: $(grep -c ">" filtered_out_reads/lower_length_fail.fasta 2>/dev/null || echo 0)"
    fi

    # B. Capture reads that are too LONG
    if [ "$MAX_LENGTH" -lt 999999999 ]; then
        seqkit seq -m $((MAX_LENGTH + 1)) "$WORK_FILE" > filtered_out_reads/upper_length_fail.fasta 2> /dev/null
        echo "  - Identified long reads: $(grep -c ">" filtered_out_reads/upper_length_fail.fasta 2>/dev/null || echo 0)"
    fi

    # C. Create the final filtered file
    seqkit seq -m "$MIN_LENGTH" -M "$MAX_LENGTH" "$WORK_FILE" > temp_filtered.fasta 2> /dev/null
    mv temp_filtered.fasta "$WORK_FILE"
    
    echo "  - Reads remaining for analysis: $(grep -c ">" "$WORK_FILE")"
    echo "-------------------------------"
else
    echo "Skipping size filtering (No limits specified)."
fi


echo "Total reads passing filters: $(grep -c ">" "$WORK_FILE")"
echo ""

# 6. Run BLAST
echo "Running BLAST..."
echo ""
blastn -subject "$WORK_FILE" \
       -query "$FULL_BARCODE_PATH" \
       -word_size "$WORD_SIZE" \
       -perc_identity "$PERC_IDENTITY" \
       -outfmt 6 > blast_all_barcodes.csv

# 7. Fast filtering (Replaces your R script)
echo "Filtering unique barcodes..."
echo ""
awk -F'\t' '!seen[$2]++ { print ">"$2 }' blast_all_barcodes.csv > unique_all_barcodes.txt

echo "Found $(wc -l < unique_all_barcodes.txt) unique sequences."
echo ""
#echo "Results: $OUTPUT_DIR/unique_all_barcodes.txt"
#echo ""


# 7. Extract unique reads from the FASTA file
echo "Extracting sequences for unique barcodes..."
echo ""

# We use -F (fixed strings) for speed and -f to pull IDs from our list
# Note: we use the $OUTPUT_FILENAME created by seqkit earlier
grep -F -A 1 -f unique_all_barcodes.txt "$WORK_FILE" > reads_with_barcodes_tmp.fasta

# Remove the '--' separators that grep adds between matches
grep -v -e '--' reads_with_barcodes_tmp.fasta > reads_with_barcodes.fasta
rm reads_with_barcodes_tmp.fasta

# 8. Run the second BLAST on the filtered reads
#echo "Running second BLAST on unique reads..."
#echo ""
blastn -subject "$WORK_FILE" \
       -query "$FULL_BARCODE_PATH" \
       -word_size "$WORD_SIZE" \
       -perc_identity "$PERC_IDENTITY" \
       -outfmt 6 > blast_unique_barcodes.csv

echo "------------------------------------------"
echo "Total filtered reads: $(grep -c ">" reads_with_barcodes.fasta)"
echo "------------------------------------------"
echo ""


# 9. Group Subject_names (read IDs) into .lst files based on Query_name (barcodes)
echo "Splitting reads into barcode-specific lists..."
echo ""

awk -F'\t' '
  !seen[$2]++ { 
    print $2 > ($1 ".lst") 
  }
' blast_unique_barcodes.csv

echo "Created barcode lists: $(ls *.lst | wc -l) files generated."
echo ""

# 10. Extract sequences for each barcode into separate FASTQ files
echo "Extracting barcode-specific FASTQ files..."
echo ""

mkdir -p recovered_reads
mv *.lst recovered_reads/
cd recovered_reads || exit 1

# 11. Final Sequence Recovery
for i in *.lst; do
    # ${i%.lst} removes the .lst extension for the output name
    seqtk subseq "$FULL_INPUT_PATH" "$i" > "${i%.lst}.fastq"
done



# 12. Concatenation Step
echo "Starting concatenation with SQK files from $SQK_FOLDER..."
echo ""

# Ensure we are inside recovered_reads where the barcodeXX.fastq files live
# We should already be there from step 11

for j in barcode*.fastq; do
    # Extract the barcode ID (e.g., "barcode05") from the filename
    BC_ID="${j%.fastq}"
    
    # Look for the matching file in the SQK folder
    # This matches "SQK_barcode05.fastq" or similar
    SQK_MATCH=$(ls "$SQK_FOLDER"/*"$BC_ID"* 2>/dev/null | head -n 1)

    if [[ -f "$SQK_MATCH" ]]; then
        echo "Found match: $BC_ID <--> $(basename "$SQK_MATCH")"
        cat "$SQK_MATCH" "$j" > "concatenated_${j}"
    else
        echo "Warning: No SQK match found for $BC_ID in $SQK_FOLDER"
    fi
done

echo ""
echo "Concatenation complete."
#echo ""

#######################
mkdir ../concatenated
mv concatenated* ../concatenated

cat *.fastq > all_recovered_barcodes.fastq
cat ../concatenated/*.fastq > ../concatenated/concatenated_all_barcodes.fastq

cd ..

cd recovered_reads
rm *.lst
cd ..

# 13. Generate Recovery Statistics
echo "Generating read count statistics..."
echo ""
STATS_FILE="recovery_statistics.csv"

# Write the header to the CSV
echo "Barcode_File,Original_Reads,Recovered_Reads,Recovery_Percentage" > "$STATS_FILE"

if [ -d "concatenated" ]; then
    (
        cd concatenated || exit
        for concat_file in *.fastq; do
            [[ -e "$concat_file" ]] || continue
            
            # 1. Calculate Total Reads (Concatenated)
            total_lines=$(wc -l < "$concat_file")
            total_reads=$((total_lines / 4))
            
            # 2. Find correspondent in recovered_reads
            orig_name="${concat_file#concatenated_}"
            recov_file="../recovered_reads/$orig_name"
            
            if [[ -f "$recov_file" ]]; then
                recov_lines=$(wc -l < "$recov_file")
                recov_reads=$((recov_lines / 4))
            else
                recov_reads=0
            fi
            
            # 3. Calculate "Original" (Total - Recovered)
            original_reads=$((total_reads - recov_reads))
            
            # 4. Calculate Ratio (Recovered / Original)
            if [ "$total_reads" -gt 0 ]; then
                percent=$(awk "BEGIN {printf \"%.3f\", ($recov_reads/$original_reads)*100}")
            else
                percent="0"
            fi

            # Append to the CSV: Original, Recovered, %
            echo "$concat_file,$original_reads,$recov_reads,${percent}%" >> "../$STATS_FILE"
        done
    )
    echo "Statistics saved to: $STATS_FILE"
    echo ""
else
    echo "Warning: Concatenated folder not found. Skipping statistics."
    echo ""
fi





# 14. Define the folders we want to analyze
ANALYSIS_DIRS=("concatenated" "recovered_reads")

for folder in "${ANALYSIS_DIRS[@]}"; do
    # NEW CHECK: If current folder is "concatenated" AND nanoplot is "off", skip it
    if [[ "$folder" == "concatenated" && "$RUN_NANOPLOT" == "off" ]]; then
        echo ">>> Skipping NanoPlot analysis for: $folder (as requested)"
        continue
    fi

    if [ -d "$folder" ]; then
        echo ""
        echo ">>> Starting NanoPlot analysis in: $folder"
        cd "$folder" || continue

        for i in *.fastq; do
            [[ -e "$i" ]] || continue

            PLOT_DIR="nanoplot_${i%.fastq}"
            mkdir -p "$PLOT_DIR"
            
            echo "Analyzing $i..."
            NanoPlot --huge -t "$THREADS" --tsv_stats --only-report --fastq "$i" -o "$PLOT_DIR"

            cd "$PLOT_DIR" || continue
            if [ -f "NanoStats.txt" ]; then
                awk '{$1=$1; print}' OFS="," NanoStats.txt > NanoStats.csv
            fi
            cd .. 
        done
        
        cd .. # Back to the main working directory
    fi
done

echo ""

# 15. Run R Summary Script
echo "Running R summary analysis..."

# Process concatenated folder
if [ -d "concatenated" ] && [ "$RUN_NANOPLOT" == "on" ]; then
    echo "Summarizing concatenated reads..."
    # The R script looks for the nanoplot_ folders created earlier
    Rscript "$CWD/nanoplot_summary.R" "$(realpath concatenated)" > /dev/null 2>&1
    sed -i 's/"//g' ./concatenated/nanoplot_summary.csv
fi

# Process recovered_reads folder
if [ -d "recovered_reads" ]; then
    echo "Summarizing recovered reads..."
    Rscript "$CWD/nanoplot_summary.R" "$(realpath recovered_reads)" > /dev/null 2>&1
    sed -i 's/"//g' ./recovered_reads/nanoplot_summary.csv
    fi


mv ../"$LOG_FILE" "$OUTPUT_DIR"
rm ../*.log 2> /dev/null

echo ""

echo "Results saved in $OUTPUT_DIR"
echo ""
