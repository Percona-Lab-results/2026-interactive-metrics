#!/usr/bin/env Rscript

# sample_cpu_echarts.R
#
# Usage:
#   Rscript sample_cpu_echarts.R cpu.log cpu_all.html

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript sample_cpu_echarts.R <input_file> <output_html>\n")
}

in_file  <- args[1]
out_file <- args[2]

suppressPackageStartupMessages({
  library(echarts4r)
  library(htmlwidgets)
})

# ---- 1. Read and clean raw lines ----
raw <- readLines(in_file, warn = FALSE)

# Drop completely empty lines
raw <- raw[nzchar(trimws(raw))]

# Keep only data lines (skip header lines that contain '%usr' etc.)
is_header <- grepl("%usr", raw, fixed = TRUE)
dat_lines <- raw[!is_header]

# ---- 2. Turn lines into a data.frame ----
# Each data line looks like:
# 11:52:33 AM  all   59.75    0.00   11.88    4.25 ...
#
# We split on whitespace, then assign columns.

split_lines <- strsplit(dat_lines, "\\s+")
max_len <- max(lengths(split_lines))

# Pad shorter rows if needed (should not happen with clean data)
split_padded <- lapply(split_lines, function(x) {
  c(x, rep(NA_character_, max_len - length(x)))
})

mat <- do.call(rbind, split_padded)

# Expecting 12 columns:
# time, AM/PM, CPU, %usr, %nice, %sys, %iowait, %irq, %soft, %steal, %guest, %gnice, %idle
# But your sample has 11 numeric cols after CPU (no extra col), so 13 tokens total:
# 1: time, 2: AM/PM, 3: CPU, 4–14: metrics
# Adjust if needed after quick inspection; here we map according to your example.

df <- data.frame(
  time_str = paste(mat[, 1], mat[, 2]), # "11:52:33 AM"
  CPU      = mat[, 3],
  usr      = as.numeric(mat[, 4]),
  nice     = as.numeric(mat[, 5]),
  sys      = as.numeric(mat[, 6]),
  iowait   = as.numeric(mat[, 7]),
  irq      = as.numeric(mat[, 8]),
  soft     = as.numeric(mat[, 9]),
  steal    = as.numeric(mat[, 10]),
  guest    = as.numeric(mat[, 11]),
  gnice    = as.numeric(mat[, 12]),
  idle     = as.numeric(mat[, 13]),
  stringsAsFactors = FALSE
)

# ---- 3. Create a proper POSIXct time axis ----
# We only have clock time (no date), so we attach an arbitrary date.
# If your log is from a known date, replace "2025-01-01" with that.

df$timestamp <- as.POSIXct(
  paste("2025-01-01", df$time_str),
  format = "%Y-%m-%d %I:%M:%S %p",
  tz = "UTC"
)

# ---- 4. Filter to CPU == 'all' (aggregate) ----
df_all <- df[df$CPU == "all", ]

if (nrow(df_all) == 0) {
  stop("No rows with CPU == 'all' found in input file.\n")
}

# ---- 5. Build interactive chart ----
p <- df_all |>
  e_charts(timestamp) |>
  e_line(usr,   name = "%usr") |>
  e_line(sys,   name = "%sys") |>
  e_line(iowait, name = "%iowait") |>
  e_line(idle,  name = "%idle") |>
  e_title("CPU usage over time (all CPUs)",
          "Data from sar-style log") |>
  e_tooltip(trigger = "axis") |>
  e_datazoom(show = TRUE) |>
  e_legend(show = TRUE)

# ---- 6. Save to HTML ----
saveWidget(p, out_file, selfcontained = TRUE)
cat("Wrote interactive chart to:", out_file, "\n")
