#!/bin/bash

# --- VARIABLES ---
DB_HOST="127.0.0.1"   # REPLACE ME
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
POOL_SIZES=(32 12 2)      # The 3 Tiers (GB)
#POOL_SIZES=(2)

#THREADS=(1 4 16 32 64 128 256)
THREADS=(128 256)

DURATION=900   # 900s 15 Minutes

DBMS_NAME="$1"
DBMS_VER="$2"
CONF_DIR="mysql/conf.d"

echo "============= Running benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="

if [[ "$DBMS_NAME" == "percona-server" ]]; then
    IMAGE_PREFIX="percona/"
    CONF_DIR="percona-server.conf.d"
fi

if [[ "$DBMS_NAME" == "mariadb" ]]; then
    ADMIN_TOOL="mariadb-admin"
else
    ADMIN_TOOL="mysqladmin"
fi  

IMAGE_NAME="${IMAGE_PREFIX}${DBMS_NAME}:${DBMS_VER}"

CONTAINER_NAME="dbms-benchmark-test"

MYSQL_ROOT_PASSWORD="password"
CONFIG_PATH="$HOME/configs/config.cnf"

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_RO_TIME=180
WARMUP_RW_TIME=600


server_wait() {
  # Wait for MySQL to be ready
  echo "Waiting for DB Server to initialize..."

  until docker exec "$CONTAINER_NAME" "$ADMIN_TOOL" ping --host=127.0.0.1 -u"root" -p"$DB_PASS" --silent; do
      sleep 2
  done
}

stop_container() {
  local CONTAINER=$1
  echo "Stopping container ${CONTAINER}"
  docker container stop "$CONTAINER"
  sleep 2
  docker container rm "$CONTAINER"
}

run_container() {
  local DIR=$1
  docker run --user mysql --rm --name "$CONTAINER_NAME" \
    --network host \
    -v "${HOME}/configs:/etc/${CONF_DIR}" \
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
rm "$CONFIG_PATH"

# --- THIS NEEDS TO BE DONE IF A VERSION IS "latest" ---
run_container "$BENCH_DIR"
server_wait 

RAW_VERSION=$(mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -N -e "SELECT VERSION();")
MAJOR_VER=$(echo $RAW_VERSION | cut -d'.' -f1,2)
IS_MARIA=$(echo $RAW_VERSION | grep -i "Maria" | wc -l)

LOG_DIR="${BENCH_DIR}/${DBMS_NAME}/${RAW_VERSION}"
mkdir -p $LOG_DIR

echo "Detected: $RAW_VERSION (Major: $MAJOR_VER, MariaDB: $IS_MARIA)"

# --- CONFIGURATION GENERATOR ---
generate_config() {
    local SIZE=$1

    # Start Config
    echo "[mysqld]" > /tmp/config.cnf
    echo "innodb_buffer_pool_size = ${SIZE}G" >> /tmp/config.cnf
    echo "max_prepared_stmt_count = 1000000" >> /tmp/config.cnf
    echo "max_connections = 4096" >> /tmp/config.cnf
    # Instance Sizing
    if [ "$SIZE" -lt 8 ]; then
        echo "innodb_buffer_pool_instances = 1" >> /tmp/config.cnf
    else
        echo "innodb_buffer_pool_instances = 8" >> /tmp/config.cnf
    fi

    # VERSION SPECIFIC LOGIC
    if [ "$IS_MARIA" -eq 1 ]; then
        # --- MARIADB ---
        echo "innodb_log_file_size = 2G" >> /tmp/config.cnf
        echo "innodb_log_files_in_group = 2" >> /tmp/config.cnf
        echo "thread_handling = one-thread-per-connection" >> /tmp/config.cnf
    elif [[ "$MAJOR_VER" == "5.7" ]]; then
        # --- MYSQL / PERCONA 5.7 ---
        echo "innodb_log_file_size = 2G" >> /tmp/config.cnf
        echo "innodb_log_files_in_group = 2" >> /tmp/config.cnf
        echo "query_cache_type = 0" >> /tmp/config.cnf   # CRITICAL DISABLE
        echo "query_cache_size = 0" >> /tmp/config.cnf
        echo "innodb_checksum_algorithm = crc32" >> /tmp/config.cnf
    elif [[ "$MAJOR_VER" == "8.0" ]]; then
        # --- MYSQL 8.0 ---
        echo "innodb_log_file_size = 2G" >> /tmp/config.cnf
        echo "innodb_log_files_in_group = 2" >> /tmp/config.cnf
        echo "innodb_change_buffering = none" >> /tmp/config.cnf
    else
        # --- MYSQL 8.4 / 9.x ---
        echo "innodb_redo_log_capacity = 4G" >> /tmp/config.cnf
        echo "innodb_change_buffering = none" >> /tmp/config.cnf
    fi

    # copy config
    cp /tmp/config.cnf $HOME/configs
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
    --tables=20 --table-size=$TABLE_ROWS --threads=16 prepare
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
