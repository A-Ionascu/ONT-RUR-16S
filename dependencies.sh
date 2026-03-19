#!/bin/bash

echo "Checking dependencies..."

# 1. Check for System Binaries
APPS=("blastn" "seqkit" "NanoPlot")
MISSING_APPS=()

for app in "${APPS[@]}"; do
    if ! command -v "$app" &> /dev/null; then
        MISSING_APPS+=("$app")
    fi
done

if [ ${#MISSING_APPS[@]} -eq 0 ]; then
    echo "✅ All system binaries (BLAST, SeqKit, NanoPlot) are installed."
else
    echo "❌ Missing: ${MISSING_APPS[*]}"
    echo "Attempting installation via Conda..."
    # If you have conda/mamba installed:
    conda install -c bioconda -c conda-forge blast seqkit nanoplot -y || {
        echo "Conda installation failed. Please install manually:"
        echo "sudo apt update && sudo apt install ncbi-blast+ seqkit"
        echo "pip install NanoPlot"
    }
fi

# 2. Check for R Packages
echo "Checking R packages (tibble, stringr)..."
R_PACKAGES='c("tibble", "stringr", "readr")'
Rscript -e "
req_pkgs <- $R_PACKAGES
inst_pkgs <- req_pkgs[!(req_pkgs %in% installed.packages()[,\"Package\"])]
if(length(inst_pkgs)) {
    install.packages(inst_pkgs, repos=\"https://cloud.r-project.org/\")
    message(\"✅ Installed missing R packages: \", paste(inst_pkgs, collapse=\", \"))
} else {
    message(\"✅ All R packages are already installed.\")
}
"

echo "Dependency check complete."

chmod +x nanoplot_summary.R
chmod +x ont_rur_16S.sh
