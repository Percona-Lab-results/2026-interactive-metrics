#!/bin/bash

# --- VARIABLES ---
REMOTE_HOST="beast-node3" 
DB_HOST="beast-node3"          
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
POOL_SIZES=(32 12 2)
THREADS=(1 4 16 32 64 128 256)
DURATION=900

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

ADMIN_TOOL=$([[ "$DBMS_NAME" == "mariadb" ]] && echo "mariadb-admin" || echo "mysqladmin")
IMAGE_NAME="${IMAGE_PREFIX}${DBMS_NAME}:${DBMS_VER}"
CONTAINER_NAME="dbms-benchmark-test"

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_RO_TIME=180
WARMUP_RW_TIME=600

# Helper function to run commands on remote host - using -Tq for cleaner output
remote_exec() {
  ssh -Tq "$REMOTE_HOST" "$@"
}

server_wait() {
  echo "Waiting for DB Server to initialize..."
  until remote_exec "docker exec $CONTAINER_NAME $ADMIN_TOOL ping --host=127.0.0.1 -u\"root\" -p\"$DB_PASS\"">/dev/null 2>&1; do
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
  # Ensure the config dir exists before mounting
  local RUN_DOCKER_CMD="docker run --user mysql --rm --name $CONTAINER_NAME \
    --network host \
    -v $REMOTE_CONFIG_DIR:/etc/$CONF_DIR \
    -e MYSQL_ROOT_PASSWORD=$DB_PASS \
    -e MYSQL_DATABASE=sbtest \
    -e MYSQL_ROOT_HOST='%' \
    -d $IMAGE_NAME"

  echo "Starting container on remote with command: $RUN_DOCKER_CMD"
  remote_exec "$RUN_DOCKER_CMD"
}

check_innodb_buffer() {
    local EXPECTED_GB=$1
    echo ">>> Verifying InnoDB Buffer Pool: ${EXPECTED_GB}GB..."

    # Run query inside the remote container
    local ACTUAL_BYTES=$(remote_exec "docker exec $CONTAINER_NAME mysql -u $DB_USER -p$DB_PASS -N -s -e \"SELECT @@innodb_buffer_pool_size;\" 2>/dev/null")
    
    # Catch empty return/errors
    if [[ -z "$ACTUAL_BYTES" ]]; then echo "Error: Could not retrieve buffer pool size"; exit 1; fi

    local ACTUAL_GB=$(( ACTUAL_BYTES / 1024 / 1024 / 1024 ))

    if [ "$ACTUAL_GB" -ne "$EXPECTED_GB" ]; then
        echo "CRITICAL ERROR: Buffer Pool is ${ACTUAL_GB}GB (Expected ${EXPECTED_GB}GB)"
        stop_container
        exit 1
    fi
    echo "Verification successful: Buffer Pool is ${ACTUAL_GB}GB."
}

generate_config() {
    local SIZE=$1
    local CFG="/tmp/config.cnf"
    sudo rm -f "$CFG"

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

    # Deploy Config via SCP then sudo move to ensure proper directory placement
    scp -q "$CFG" "${REMOTE_HOST}:/tmp/config.cnf"
    remote_exec "mkdir -p $REMOTE_CONFIG_DIR && sudo mv /tmp/config.cnf $REMOTE_CONFIG_DIR/config.cnf"
    remote_exec "chmod 644 ${REMOTE_CONFIG_DIR}/config.cnf"
}

start_metrics() {
    local REMOTE_PREFIX=$1
    echo " --- START REMOTE METRICS ---"
    remote_exec "mkdir -p \$(dirname \"$REMOTE_PREFIX\")"
    remote_exec "iostat -dxm 1 > \"${REMOTE_PREFIX}.iostat\" 2>/dev/null & echo \$! > /tmp/iostat.pid"
    remote_exec "vmstat 1 > \"${REMOTE_PREFIX}.vmstat\" 2>/dev/null & echo \$! > /tmp/vmstat.pid"
    remote_exec "mpstat -P ALL 1 > \"${REMOTE_PREFIX}.mpstat\" 2>/dev/null & echo \$! > /tmp/mpstat.pid"
}

stop_metrics() {
    remote_exec "kill \$(cat /tmp/iostat.pid /tmp/vmstat.pid /tmp/mpstat.pid) 2>/dev/null"
}

init_data() {
  echo ">>> Local Sysbench: Preparing data on $DB_HOST..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=16 prepare
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
RAW_VERSION=$(remote_exec "docker exec $CONTAINER_NAME mysql -u $DB_USER -p$DB_PASS -N -s -e \"SELECT VERSION();\"")
MAJOR_VER=$(echo "$RAW_VERSION" | cut -d'.' -f1,2)
IS_MARIA=$(echo "$RAW_VERSION" | grep -iq "Maria" && echo 1 || echo 0)

# Synchronize directory structures
LOCAL_LOG_DIR="./benchmark_logs/${DBMS_NAME}/${RAW_VERSION}"
REMOTE_LOG_DIR="${REMOTE_BASE_LOG_DIR}/${DBMS_NAME}/${RAW_VERSION}"

mkdir -p "$LOCAL_LOG_DIR"
remote_exec "mkdir -p \"$REMOTE_LOG_DIR\""

echo "Detected: $RAW_VERSION | Logging to: $LOCAL_LOG_DIR"

for SIZE in "${POOL_SIZES[@]}"; do
  generate_config "$SIZE"
  stop_container
  run_container
  server_wait
  check_innodb_buffer "$SIZE"
  init_data
  
  for THREAD in "${THREADS[@]}"; do
    FILE_NAME="Tier${SIZE}G_RW_${THREAD}th"
    LOCAL_PREFIX="${LOCAL_LOG_DIR}/${FILE_NAME}"
    REMOTE_PREFIX="${REMOTE_LOG_DIR}/${FILE_NAME}"

    start_metrics "$REMOTE_PREFIX"

    echo "   >>> Testing $THREAD Threads..."
    sysbench oltp_read_write \
      --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
      --tables=20 --table-size=$TABLE_ROWS --threads=$THREAD \
      --time=$DURATION --report-interval=1 \
      run > "${LOCAL_PREFIX}.sysbench"

    stop_metrics
    
    # Pull matching files back
    scp -q "${REMOTE_HOST}:${REMOTE_PREFIX}.*" "$LOCAL_LOG_DIR/"
    sleep 5
  done
  stop_container
done
