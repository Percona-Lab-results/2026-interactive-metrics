#!/bin/bash

# --- VARIABLES ---
REMOTE_HOST="beast-node3"
DB_HOST="beast-node3"
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
POOL_SIZES=(32 12 2)
THREADS=(1 4 16 32 64 128 256 512)

# POOL_SIZES=(2)
# THREADS=(1)

DBMS_NAME="$1"
DBMS_VER="$2"
CONF_DIR="mysql/conf.d"

# Base Remote Paths
REMOTE_CONFIG_DIR="$HOME/configs"
REMOTE_BASE_LOG_DIR="benchmark_logs" # Relative to $HOME

echo "============= Running benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="

if [[ "$DBMS_NAME" == "percona-server" ]]; then
    IMAGE_PREFIX="percona/"
    CONF_DIR="my.cnf.d"
fi

if [[ "$DBMS_NAME" == "mariadb" ]]; then
    ADMIN_TOOL="mariadb-admin"
    CMD_TOOL="mariadb"
else
    ADMIN_TOOL="mysqladmin"
    CMD_TOOL="mysql"
fi  

IMAGE_NAME="${IMAGE_PREFIX}${DBMS_NAME}:${DBMS_VER}"
CONTAINER_NAME="dbms-benchmark-test"

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_RO_TIME=180
WARMUP_RW_TIME=600
DURATION=900

# --- DEBUG SETTINGS ---
# TABLE_ROWS=50000
# WARMUP_RO_TIME=10
# WARMUP_RW_TIME=10
# DURATION=30

# Helper function to run commands on remote host
remote_exec() {
  ssh -Tq "$REMOTE_HOST" "$@"
}

server_wait() {
  echo "Waiting for DB Server to initialize..."
  sleep 5

  # Check that the container exists and is running
  # if [[ "$(remote_exec "docker inspect -f '{{.State.Running}}' '$CONTAINER_NAME' 2>/dev/null")" != "true" ]]; then
  #   echo "Fatal error: container '$CONTAINER_NAME' is not running or does not exist. Terminating script."
  #   exit 1
  # fi

  until remote_exec "docker exec $CONTAINER_NAME $ADMIN_TOOL ping --host=127.0.0.1 -u\"root\" -p\"$DB_PASS\"" >/dev/null 2>&1; do
    echo "   ... still waiting for DB to be responsive ..."
    sleep 2
  done
}

stop_container() {
  echo "Stopping container on remote..."
  remote_exec "docker container stop $CONTAINER_NAME && docker container rm $CONTAINER_NAME" 2>/dev/null
  sleep 2
}

run_container() {
  local RUN_DOCKER_CMD="docker run --user mysql --rm --name $CONTAINER_NAME \
    --network host \
    -v $REMOTE_CONFIG_DIR:/etc/$CONF_DIR \
    -e MYSQL_ROOT_PASSWORD=$DB_PASS \
    -e MYSQL_DATABASE=$DB_DATABASE \
    -e MYSQL_ROOT_HOST='%' \
    -d $IMAGE_NAME"

  echo "Starting container on remote with command: $RUN_DOCKER_CMD"
  remote_exec "$RUN_DOCKER_CMD"
}

check_innodb_buffer() {
  local EXPECTED_GB=$1
  echo ">>> Verifying InnoDB Buffer Pool: ${EXPECTED_GB}GB..."

  local ACTUAL_BYTES
  ACTUAL_BYTES=$(remote_exec "docker exec $CONTAINER_NAME $CMD_TOOL -u $DB_USER -p$DB_PASS -N -s -e \"SELECT @@innodb_buffer_pool_size;\" 2>/dev/null")

  if [[ -z "$ACTUAL_BYTES" ]]; then
    echo "Error: Could not retrieve buffer pool size"
    exit 1
  fi

  local ACTUAL_GB=$(( ACTUAL_BYTES / 1024 / 1024 / 1024 ))

  if [ "$ACTUAL_GB" -ne "$EXPECTED_GB" ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "CRITICAL ERROR: Buffer Pool is ${ACTUAL_GB}GB (Expected ${EXPECTED_GB}GB)"
    echo "Aborting entire benchmark script immediately."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    stop_container
    exit 1
  fi
  echo "Verification successful: Buffer Pool is ${ACTUAL_GB}GB."
}

check_vars_status() {
  local FILE_PREFIX=$1
  echo ">>> Capturing server variables and status..."

  remote_exec "docker exec $CONTAINER_NAME $CMD_TOOL -u $DB_USER -p$DB_PASS -N -e \"SHOW VARIABLES;\" 2>/dev/null" > "${FILE_PREFIX}.vars.txt"
  if [ $? -eq 0 ]; then
    echo "    Variables saved to: ${FILE_PREFIX}.vars.txt"
  else
    echo "    ERROR: Failed to capture variables"
  fi

  remote_exec "docker exec $CONTAINER_NAME $CMD_TOOL -u $DB_USER -p$DB_PASS -N -e \"SHOW STATUS;\" 2>/dev/null" > "${FILE_PREFIX}.status.txt"
  if [ $? -eq 0 ]; then
    echo "    Status saved to: ${FILE_PREFIX}.status.txt"
  else
    echo "    ERROR: Failed to capture status"
  fi
}

run_mysql_summary() {
  local FILE_PREFIX=$1
  ./pt-mysql-summary --host="$DB_HOST" --user="$DB_USER" --password="$DB_PASS" > "${FILE_PREFIX}-pt-mysql-summary.txt"
  if [ $? -eq 0 ]; then
    echo "    Server summary saved to: ${FILE_PREFIX}-pt-mysql-summary.txt"
  else
    echo "    ERROR: Failed to capture server summary with pt-mysql-summary"
  fi
}

generate_config() {
  local SIZE=$1
  local CFG="/tmp/config.cnf"
  sudo rm -f "$CFG"

  # 1. Base Config
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
  echo "connect_timeout = 60" >> "$CFG"
  echo "character_set_server = utf8mb4" >> "$CFG"

  echo "innodb_doublewrite = 1" >> "$CFG"
  echo "innodb_flush_log_at_trx_commit = 1" >> "$CFG"
  echo "innodb_flush_method = O_DIRECT" >> "$CFG"
  echo "innodb_log_buffer_size = 64M" >> "$CFG"

  echo "server_id = 1" >> "$CFG"
  echo "log_bin = binlog" >> "$CFG"
  echo "sync_binlog = 1" >> "$CFG"
  echo "binlog_format = ROW" >> "$CFG"
  echo "binlog_row_image = MINIMAL" >> "$CFG"

  # 2. Instance Sizing
  if [ "$SIZE" -lt 8 ]; then
    echo "innodb_buffer_pool_instances = 1" >> "$CFG"
  else
    echo "innodb_buffer_pool_instances = 8" >> "$CFG"
  fi

  # 3. Version-Specific Logic
  if [ "$IS_MARIA" -eq 1 ]; then
    # --- MARIADB ---
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
    echo "innodb_log_file_size = 2G" >> "$CFG"
    echo "innodb_log_files_in_group = 2" >> "$CFG"
    echo "innodb_change_buffering = none" >> "$CFG"

  else
    # --- MYSQL 8.4 / 9.x ---
    echo "innodb_redo_log_capacity = 4G" >> "$CFG"
    echo "innodb_change_buffering = none" >> "$CFG"
  fi

  # 4. Deploy Config via SCP then move on remote
  scp -q "$CFG" "${REMOTE_HOST}:/tmp/config.cnf"
  remote_exec "mkdir -p $REMOTE_CONFIG_DIR && sudo mv /tmp/config.cnf $REMOTE_CONFIG_DIR/config.cnf"
  remote_exec "chmod 644 ${REMOTE_CONFIG_DIR}/config.cnf"

  # 5. Save a copy of the config locally for reference
  cp "$CFG" "${LOCAL_LOG_DIR}/Tier${SIZE}G.cnf.txt"
}

start_metrics() {
  local REMOTE_PREFIX=$1
  echo " --- START REMOTE METRICS ---"
  remote_exec "mkdir -p \$(dirname \"$REMOTE_PREFIX\")"
  remote_exec "iostat -dxm 1 > \"${REMOTE_PREFIX}.iostat.txt\" 2>/dev/null & echo \$! > /tmp/iostat.pid"
  remote_exec "vmstat 1 > \"${REMOTE_PREFIX}.vmstat.txt\" 2>/dev/null & echo \$! > /tmp/vmstat.pid"
  remote_exec "mpstat -P ALL 1 > \"${REMOTE_PREFIX}.mpstat.txt\" 2>/dev/null & echo \$! > /tmp/mpstat.pid"
  remote_exec "dstat -v > \"${REMOTE_PREFIX}.dstat.txt\" 2>/dev/null & echo \$! > /tmp/dstat.pid"
}

stop_metrics() {
  remote_exec "kill \$(cat /tmp/iostat.pid /tmp/vmstat.pid /tmp/mpstat.pid /tmp/dstat.pid) 2>/dev/null"
}

init_data() {
  echo ">>> Create tables and insert data..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=64 prepare
}

remove_old_config() {
  echo "Cleaning up old config on remote..."
  remote_exec "sudo rm -f $REMOTE_CONFIG_DIR/config.cnf"
}

# --- MAIN EXECUTION ---
remove_old_config
stop_container
run_container
server_wait

# Detect version inside container
RAW_VERSION=$(remote_exec "docker exec $CONTAINER_NAME $CMD_TOOL -u $DB_USER -p$DB_PASS -N -s -e \"SELECT VERSION();\"")
MAJOR_VER=$(echo "$RAW_VERSION" | cut -d'.' -f1,2)
IS_MARIA=$(echo "$RAW_VERSION" | grep -iq "Maria" && echo 1 || echo 0)

# Synchronize directory structures
LOCAL_LOG_DIR="./benchmark_logs/${DBMS_NAME}/${RAW_VERSION}"
REMOTE_LOG_DIR="${REMOTE_BASE_LOG_DIR}/${DBMS_NAME}/${RAW_VERSION}"

mkdir -p "$LOCAL_LOG_DIR"
remote_exec "mkdir -p \"$REMOTE_LOG_DIR\""

echo "Detected: $RAW_VERSION | Logging to: $LOCAL_LOG_DIR"

# --- EXECUTION LOOP ---
for SIZE in "${POOL_SIZES[@]}"; do
  echo "========================================================="
  echo ">>> TIER: ${SIZE}GB | VER: $RAW_VERSION <<<"
  echo "========================================================="

  # 1. Apply Config & Restart
  generate_config "$SIZE"
  stop_container
  run_container
  server_wait
  check_innodb_buffer "$SIZE"
  check_vars_status "${LOCAL_LOG_DIR}/Tier${SIZE}G"
  init_data
  run_mysql_summary "${LOCAL_LOG_DIR}/Tier${SIZE}G"

  # 2. Warmup (Reads then Writes)
  echo ">>> Warmup A: Read-Only (${WARMUP_RO_TIME}s)..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=16 --time=$WARMUP_RO_TIME run

  echo ">>> Warmup B: Dirty Writes (${WARMUP_RW_TIME}s)..."
  sysbench oltp_read_write --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --mysql-db=$DB_DATABASE --tables=20 --table-size=$TABLE_ROWS --threads=64 --time=$WARMUP_RW_TIME run

  # 3. Measurement
  for THREAD in "${THREADS[@]}"; do
    FILE_NAME="Tier${SIZE}G_RW_${THREAD}th"
    LOCAL_PREFIX="${LOCAL_LOG_DIR}/${FILE_NAME}"
    REMOTE_PREFIX="${REMOTE_LOG_DIR}/${FILE_NAME}"

    echo "   >>> Testing ${THREAD} Threads..."
    start_metrics "$REMOTE_PREFIX"

    sysbench oltp_read_write \
      --mysql-host=$DB_HOST \
      --mysql-user=$DB_USER \
      --mysql-password=$DB_PASS \
      --mysql-db=$DB_DATABASE \
      --tables=20 \
      --table-size=$TABLE_ROWS \
      --threads=$THREAD \
      --time=$DURATION \
      --report-interval=1 \
      --rand-type=uniform \
      --mysql-ssl=off \
      run > "${LOCAL_PREFIX}.sysbench.txt"

    stop_metrics

    # Pull remote metric files back locally
    scp -q "${REMOTE_HOST}:${REMOTE_PREFIX}.*" "$LOCAL_LOG_DIR/"
    sleep 10
  done

  stop_container
done

echo "============= Finished benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="