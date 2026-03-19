# List packages to check installation
packages <- c("tibble","stringr")
# Install packages not yet installed
installed_packages <- packages %in% rownames(installed.packages())
if (any(installed_packages == FALSE)) {
  install.packages(packages[!installed_packages])
}
# Packages loading
suppressWarnings(suppressMessages(invisible(lapply(packages, library, character.only = TRUE))))


# summarize_nanoplot.R
args <- commandArgs(trailingOnly = TRUE)
# If an argument is provided, use it; otherwise, use current directory
mainDir <- if(length(args) > 0) args[1] else getwd()

setwd(mainDir)
directories <- list.dirs(path = ".", recursive = FALSE)

table <- data.frame(matrix(NA, nrow=13, ncol=1))
colnames(table) <- c("t")
rownames(table) <- c("reads","bases","mean_length","median_length","length_stdev",
                     "N50","mean_quality","median_quality","Q>5","Q>7","Q>10","Q>12","Q>15")

for(d in directories){
  # Only process directories starting with "nanoplot_"
  if(!grepl("nanoplot_", d)) next
  
  dir <- gsub("./","",d)
  path <- file.path(mainDir, dir)
  
  # Check if file exists before trying to read
  stats_file <- file.path(path, "NanoStats.csv")
  if(!file.exists(stats_file)) next
  
  nanoplot <- readr::read_csv(stats_file, col_names = TRUE, show_col_types = FALSE)  
  nanoplot <- as.data.frame(nanoplot)
  
  data <- data.frame(matrix(NA, nrow=13, ncol=1))
  # Adjust substring logic if needed based on folder name length
  colnames(data) <- c(dir) 
  rownames(data) <- rownames(table)
  
  # Extract values
  data[1:8, 1] <- as.numeric(nanoplot[1:8, 2])
  
  # Regex for Q-scores
  for(i in 9:13){
    row_idx <- i + 10 # Maps 9->19, 10->20, etc.
    data[i,1] <- stringr::str_extract(string = nanoplot[row_idx, 2], 
                                      pattern = "(?<=\\().*(?=\\%)")
  }
  
  table <- cbind(table, data)
}

table <- table[,-1, drop=FALSE] # Remove the dummy column
write.csv(table, "nanoplot_summary.csv", row.names = TRUE)