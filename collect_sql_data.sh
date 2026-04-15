#!/bin/bash

# Usage: collect_sql.sh <output_file> <user> <password> [host] [port] <count> <query> [compress]
#
# Examples:
#   collect_sql.sh out.csv root pass 127.0.0.1 3306 900 "SELECT ..." 1
#   collect_sql.sh out.csv root pass 127.0.0.1 3306 900 "SELECT ..." 0

OUTPUT_FILE="$1"
MYSQL_USER="$2"
MYSQL_PASS="$3"
MYSQL_HOST="${4:-127.0.0.1}"
MYSQL_PORT="${5:-3306}"
COUNT="$6"
QUERY="$7"
COMPRESS="${8:-0}"

if [ -z "$OUTPUT_FILE" ] || [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASS" ] || [ -z "$COUNT" ] || [ -z "$QUERY" ]; then
    echo "Usage: $0 <output_file> <user> <password> [host] [port] <count> <query> [compress]"
    exit 1
fi

MYSQL_CMD="mysql -u$MYSQL_USER -p$MYSQL_PASS -h$MYSQL_HOST -P$MYSQL_PORT"

# --- Derive CSV header from query column names ---
HEADER=$($MYSQL_CMD -e "$QUERY" 2>/dev/null | head -1 | tr '\t' ',')

if [ -z "$HEADER" ]; then
    echo "ERROR: Could not connect to DB or query returned no columns."
    exit 1
fi

echo "timestamp,$HEADER" > "$OUTPUT_FILE"
echo "Header written: timestamp,$HEADER"

# --- Collection loop ---
COLLECTED=0
while [ "$COLLECTED" -lt "$COUNT" ]; do
    # Fetch data rows (skip header with -N), tab-separated → comma-separated
    ROWS=$($MYSQL_CMD -Ne "$QUERY" 2>/dev/null | tr '\t' ',')

    TS=$(date '+%Y-%m-%d %H:%M:%S')

    if [ $? -eq 0 ] && [ -n "$ROWS" ]; then
        while IFS= read -r row; do
            echo "${TS},${row}" >> "$OUTPUT_FILE"
        done <<< "$ROWS"
    else
        echo "${TS},ERROR" >> "$OUTPUT_FILE"
    fi

    (( COLLECTED++ ))
    sleep 1
done

# --- Compress and remove original ---
if [ "$COMPRESS" == "1" ]; then
    echo "Compressing $OUTPUT_FILE..."
    gzip "$OUTPUT_FILE"
    echo "Done: ${OUTPUT_FILE}.gz"
else
    echo "Compression skipped. Output file: $OUTPUT_FILE"
fi