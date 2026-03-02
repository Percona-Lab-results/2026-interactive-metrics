#!/usr/bin/env Rscript

# Load necessary libraries
if (!require("stringr")) install.packages("stringr")
if (!require("htmltools")) install.packages("htmltools")

library(stringr)
library(htmltools)

# Define the base directory
base_dir <- "benchmark_logs"

# 1. Find all .sysbench files recursively
files <- list.files(path = base_dir, pattern = "\\.sysbench$", recursive = TRUE, full.names = TRUE)

# Function to extract data and format the header
process_benchmark_file <- function(file_path) {
  # Read file content
  lines <- readLines(file_path, warn = FALSE)
  content <- paste(lines, collapse = "\n")
  
  # Extract folder parts (e.g., mysql, 9.6.0)
  path_parts <- str_split(file_path, "/")[[1]]
  db_type <- path_parts[2]
  version <- path_parts[3]
  
  # Extract info from filename (e.g., Tier32G_RW_64th.sysbench)
  file_name <- tail(path_parts, 1)
  memory <- str_extract(file_name, "\\d+G") %>% str_replace("G", "G")
  concurrency <- str_extract(file_name, "\\d+th")
  
  # Create the clean header: mysql - 9.6.0 - 32G - 64th
  header_title <- sprintf("%s - %s - %s - %s", db_type, version, memory, concurrency)
  
  # Extract the specific lines using Regex
  trans_line <- str_extract(content, "transactions:.*\\)")
  query_line <- str_extract(content, "queries:.*\\)")
  
  # Return as an HTML fragment
  tags$div(
    style = "margin-bottom: 20px; font-family: monospace; border-left: 4px solid #333; padding-left: 15px;",
    tags$h3(header_title, style = "margin-bottom: 5px;"),
    tags$pre(
        paste0("    ", trans_line, "\n", "    ", query_line)
    )
  )
}

# 2. Process all files into a list of HTML elements
report_elements <- lapply(files, process_benchmark_file)

# 3. Wrap in a basic HTML structure
final_html <- tags$html(
  tags$head(
    tags$title("Benchmark Results Report"),
    tags$style("body { font-family: sans-serif; padding: 40px; background-color: #f4f4f4; }
                .container { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }")
  ),
  tags$body(
    tags$div(class = "container",
      tags$h1("Sysbench Performance Summary"),
      tags$hr(),
      report_elements
    )
  )
)

# 4. Save to file
save_html(final_html, "benchmark_report.html")

cat("Processing complete. Report generated as 'benchmark_report.html'\n")