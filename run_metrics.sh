#!/bin/bash

# --- VARIABLES ---
DB_HOST="127.0.0.1"   # REPLACE ME
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
#POOL_SIZES=(32 12 2)      # The 3 Tiers (GB)
POOL_SIZES=(32)

#THREADS=(1 4 16 32 64 128 256)
THREADS=(128)

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_RO_TIME=180
WARMUP_RW_TIME=600
DURATION=900

# TABLE_ROWS=50000
# WARMUP_RO_TIME=30
# WARMUP_RW_TIME=30
# DURATION=60

DBMS_NAME="$1"
DBMS_VER="$2"
CONF_D_DIR="mysql/conf.d"

echo "============= Running benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="

if [[ "$DBMS_NAME" == "percona-server" ]]; then
    IMAGE_PREFIX="percona/"
    CONF_D_DIR="my.cnf.d"
fi

if [[ "$DBMS_NAME" == "mariadb" ]]; then
    ADMIN_TOOL="mariadb-admin"
else
    ADMIN_TOOL="mysqladmin"
fi  

IMAGE_NAME="${IMAGE_PREFIX}${DBMS_NAME}:${DBMS_VER}"

CONTAINER_NAME="dbms-benchmark-test"

MYSQL_ROOT_PASSWORD="password"
CONFIG_DIR="$HOME/configs"
CONFIG_PATH="$CONFIG_DIR/config.cnf"
    
server_wait() {
  # Wait for MySQL to be ready
  echo "Waiting for DB Server to initialize..."

  until docker exec "$CONTAINER_NAME" "$ADMIN_TOOL" ping --host=127.0.0.1 -u"root" -p"$DB_PASS" 2>/dev/null; do
    echo "Waiting..."       
    sleep 2
  done
}

stop_container() {
  local CONTAINER=$1
  echo "Stopping container ${CONTAINER}"
  docker container stop "$CONTAINER" 2>/dev/null
  sleep 2
  docker container rm "$CONTAINER" 2>/dev/null
}

run_container() {
  local DIR=$1
  docker run --user mysql --rm --name "$CONTAINER_NAME" \
    --network host \
    -v "${CONFIG_DIR}:/etc/${CONF_D_DIR}" \
    -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
    -e MYSQL_DATABASE="sbtest" \
    -e MYSQL_ROOT_HOST='%' \
    -d ${IMAGE_NAME}
}

# Make sure no containers are running at this stage.
stop_container "$CONTAINER_NAME"

# --- DETECT VERSION & VENDOR ---
echo "Run container to detect the version of the server"

BENCH_DIR="./benchmark_logs"
echo "Removing old config if exists: $CONFIG_PATH"
sudo rm -rf "$CONFIG_PATH"

# --- THIS NEEDS TO BE DONE IF A VERSION IS "latest" ---
run_container "$BENCH_DIR"
server_wait 

RAW_VERSION=$(mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -N -e "SELECT VERSION();" 2>/dev/null)
MAJOR_VER=$(echo $RAW_VERSION | cut -d'.' -f1,2)
IS_MARIA=$(echo $RAW_VERSION | grep -i "Maria" | wc -l)

LOG_DIR="${BENCH_DIR}/${DBMS_NAME}/${RAW_VERSION}"
mkdir -p $LOG_DIR

echo "Detected: $RAW_VERSION (Major: $MAJOR_VER, MariaDB: $IS_MARIA)"

check_innodb_buffer() {
    local EXPECTED_GB=$1
    echo ">>> Verifying InnoDB Buffer Pool: ${EXPECTED_GB}GB..."

    # Get the value in bytes and divide by 1024^3 to get GB
    # Note: MySQL returns an integer; we use shell arithmetic to convert
    local ACTUAL_BYTES=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -N -s -e "SELECT @@innodb_buffer_pool_size;" 2>/dev/null)
    local ACTUAL_GB=$(( ACTUAL_BYTES / 1024 / 1024 / 1024 ))

    if [ "$ACTUAL_GB" -ne "$EXPECTED_GB" ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "CRITICAL ERROR: Buffer Pool is ${ACTUAL_GB}GB (Expected ${EXPECTED_GB}GB)"
        echo "Aborting entire benchmark script immediately."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        
        docker stop "$CONTAINER_NAME" 2>/dev/null
        # Immediate termination of the script
        exit 1
    fi

    echo "Verification successful: Buffer Pool is ${ACTUAL_GB}GB."
}

check_vars_status() {
    local FILE_PREFIX=$1
    echo ">>> Capturing server variables and status..."

    # Capture MySQL server variables into file
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW VARIABLES;" > "${FILE_PREFIX}.vars" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "    Variables saved to: ${FILE_PREFIX}.vars"
    else
        echo "    ERROR: Failed to capture variables"
    fi

    # Capture MySQL server status into file
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -N -e "SHOW STATUS;" > "${FILE_PREFIX}.status" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "    Status saved to: ${FILE_PREFIX}.status"
    else
        echo "    ERROR: Failed to capture status"
    fi
}

# --- CONFIGURATION GENERATOR ---
generate_config() {
    local SIZE=$1
    local CFG="/tmp/config.cnf"
    rm "$CFG"

    # 1. Start Base Config
    echo "[mysqld]" > "$CFG"
    echo "innodb_buffer_pool_size = ${SIZE}G" >> "$CFG"
    echo "max_prepared_stmt_count = 1000000" >> "$CFG"
    echo "max_connections = 4096" >> "$CFG"
    echo "join_buffer_size = 256K" >> "$CFG"
    echo "sort_buffer_size = 256K" >> "$CFG"
    echo "innodb_io_capacity = 2500" >> "$CFG"
    echo "innodb_io_capacity_max = 5000" >> "$CFG"
    echo "table_open_cache = 200000" >> "$CFG"
    echo "table_open_cache_instances = 64" >> "$CFG"
    echo "back_log = 3500" >> "$CFG"

    # 2. Instance Sizing
    if [ "$SIZE" -lt 8 ]; then
        echo "innodb_buffer_pool_instances = 1" >> "$CFG"
    else
        echo "innodb_buffer_pool_instances = 8" >> "$CFG"
    fi

    # 3. VERSION SPECIFIC LOGIC
    if [ "$IS_MARIA" -eq 1 ]; then
        # --- MARIADB ---
        # Query Cache removed in 12.1+
        if [ "${MAJOR_VER%%.*}" -lt 12 ]; then
            echo "query_cache_type = 0" >> "$CFG"
            echo "query_cache_size = 0" >> "$CFG"
        fi
        echo "innodb_log_file_size = 2G" >> "$CFG"
        echo "innodb_log_files_in_group = 2" >> "$CFG"
        echo "thread_handling = one-thread-per-connection" >> "$CFG"

    elif [[ "$MAJOR_VER" == "5.7" ]]; then
        # --- MYSQL / PERCONA 5.7 ---
        echo "innodb_log_file_size = 2G" >> "$CFG"
        echo "innodb_log_files_in_group = 2" >> "$CFG"
        echo "query_cache_type = 0" >> "$CFG"
        echo "query_cache_size = 0" >> "$CFG"
        echo "innodb_checksum_algorithm = crc32" >> "$CFG"

    elif [[ "$MAJOR_VER" == "8.0" ]]; then
        # --- MYSQL / PERCONA 8.0 ---
        # NOTE: query_cache is REMOVED. Including it here prevents startup.
        echo "innodb_log_file_size = 2G" >> "$CFG"
        echo "innodb_log_files_in_group = 2" >> "$CFG"
        echo "innodb_change_buffering = none" >> "$CFG"

    else
        # --- MYSQL 8.4 / 9.x ---
        # Modern redo log handling
        echo "innodb_redo_log_capacity = 4G" >> "$CFG"
        echo "innodb_change_buffering = none" >> "$CFG"
    fi

    # 4. Deploy Config
    # Ensure directory exists and copy
    mkdir -p "$CONFIG_DIR"
    sudo cp "$CFG" "$CONFIG_PATH"

    # Optional: Fix permissions to ensure Docker mysql user can read it
    sudo chmod 644 "$CONFIG_PATH"
}


# --- TELEMETRY FUNCTIONS ---
start_metrics() {
    local PREFIX=$1
    echo " --- START METRICS ---"
    echo "iostat -dxm 1 > ${PREFIX}.iostat & echo \$! > /tmp/iostat.pid"
    echo "vmstat 1 > ${PREFIX}.vmstat & echo \$! > /tmp/vmstat.pid"
    echo "mpstat -P ALL 1 > ${PREFIX}.mpstat & echo \$! > /tmp/mpstat.pid"

    iostat -dxm 1 > ${PREFIX}.iostat & echo $! > /tmp/iostat.pid
    vmstat 1 > ${PREFIX}.vmstat & echo $! > /tmp/vmstat.pid
    mpstat -P ALL 1 > ${PREFIX}.mpstat & echo $! > /tmp/mpstat.pid
}

stop_metrics() {
    kill $(cat /tmp/iostat.pid) $(cat /tmp/vmstat.pid) $(cat /tmp/mpstat.pid) 2>/dev/null
}

init_data() {
  # echo ">>> Resetting databases..."
  # docker exec "$CONTAINER_NAME" mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -N -e "DROP DATABASE IF EXISTS ${DB_DATABASE}; CREATE DATABASE ${DB_DATABASE};"

  echo ">>> Create tables and insert data..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=64 prepare
}


# --- EXECUTION LOOP ---
for SIZE in "${POOL_SIZES[@]}"; do
  echo "========================================================="
  echo ">>> TIER: ${SIZE}GB | VER: $RAW_VERSION <<<"
  echo "========================================================="

  # 1. Apply Config & Restart
  generate_config $SIZE

  stop_container $CONTAINER_NAME

  echo "Starting server with the new config..."
  run_container "$LOG_DIR" "$CONTAINER_NAME"
  server_wait "$CONTAINER_NAME"
  echo "Container restarted with custom config."
  check_innodb_buffer $SIZE
  check_vars_status "${LOG_DIR}/Tier${SIZE}G"
  init_data
  
  # 2. WARMUP (Reads then Writes)
  echo ">>> Warmup A: Read-Only (${WARMUP_RO_TIME}s)..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=16 --time=$WARMUP_RO_TIME run

  echo ">>> Warmup B: Dirty Writes (${WARMUP_RW_TIME}s)..."
  sysbench oltp_read_write --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=64 --time=$WARMUP_RW_TIME run

  # 3. MEASUREMENT
  for THREAD in "${THREADS[@]}"; do
      FILE_PREFIX="${LOG_DIR}/Tier${SIZE}G_RW_${THREAD}th"
      echo "   >>> Testing ${THREAD} Threads..."

      start_metrics "$FILE_PREFIX"

      sysbench oltp_read_write \
        --mysql-host=$DB_HOST \
        --mysql-user=$DB_USER \
        --mysql-password=$DB_PASS \
        --tables=20 \
        --table-size=$TABLE_ROWS \
        --threads=$THREAD \
        --time=$DURATION \
        --report-interval=1 \
        run > "${FILE_PREFIX}.sysbench"

    stop_metrics
    sleep 15
  done

  stop_container "$CONTAINER_NAME"
done
echo "============= Finished benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="
