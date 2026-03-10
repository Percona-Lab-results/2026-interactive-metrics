#!/bin/bash

# --- VARIABLES ---
REMOTE_HOST="user@remote-ip-address" # REPLACE ME
DB_HOST="remote-ip-address"          # The IP sysbench uses to connect
DB_USER="root"
DB_PASS="password"
DB_DATABASE="sbtest"
POOL_SIZES=(32 12 2)
THREADS=(128 256)
DURATION=900

DBMS_NAME="$1"
DBMS_VER="$2"
CONF_DIR="mysql/conf.d"

# Remote Paths
REMOTE_CONFIG_DIR="~/configs"
REMOTE_LOG_DIR="~/benchmark_logs"

echo "============= Running benchmarks for ${DBMS_NAME}:${DBMS_VER} ============="

if [[ "$DBMS_NAME" == "percona-server" ]]; then
    IMAGE_PREFIX="percona/"
    CONF_DIR="my.cnf.d"
fi

ADMIN_TOOL=$([[ "$DBMS_NAME" == "mariadb" ]] && echo "mariadb-admin" || echo "mysqladmin")
IMAGE_NAME="${IMAGE_PREFIX}${DBMS_NAME}:${DBMS_VER}"
CONTAINER_NAME="dbms-benchmark-test"
MYSQL_ROOT_PASSWORD="password"

# --- DEBUG SETTINGS ---
TABLE_ROWS=5000000
WARMUP_RO_TIME=180
WARMUP_RW_TIME=600

# Helper function to run commands on remote host
remote_exec() {
  ssh -q "$REMOTE_HOST" "$@"
}

server_wait() {
  echo "Waiting for DB Server to initialize..."
  until remote_exec "docker exec $CONTAINER_NAME $ADMIN_TOOL ping --host=127.0.0.1 -u\"root\" -p\"$DB_PASS\" --silent"; do
      sleep 2
  done
}

stop_container() {
  echo "Stopping container on remote..."
  remote_exec "docker container stop $CONTAINER_NAME && docker container rm $CONTAINER_NAME" 2>/dev/null
  sleep 2
}

run_container() {
  remote_exec "docker run --user mysql --rm --name $CONTAINER_NAME \
    --network host \
    -v $REMOTE_CONFIG_DIR:/etc/$CONF_DIR \
    -e MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD \
    -e MYSQL_DATABASE=sbtest \
    -e MYSQL_ROOT_HOST='%' \
    -d $IMAGE_NAME"
}

# --- CONFIGURATION GENERATOR ---
generate_config() {
    local SIZE=$1
    local LOCAL_CFG="/tmp/config.cnf"
    
    # [Logic stays same as your original script...]
    echo "[mysqld]" > "$LOCAL_CFG"
    echo "innodb_buffer_pool_size = ${SIZE}G" >> "$LOCAL_CFG"
    # ... (rest of your generation logic) ...
    echo "innodb_redo_log_capacity = 4G" >> "$LOCAL_CFG"

    # Push to remote
    remote_exec "mkdir -p $REMOTE_CONFIG_DIR"
    scp -q "$LOCAL_CFG" "${REMOTE_HOST}:${REMOTE_CONFIG_DIR}/config.cnf"
    remote_exec "chmod 644 ${REMOTE_CONFIG_DIR}/config.cnf"
}

# --- TELEMETRY FUNCTIONS (Running on Remote) ---
start_metrics() {
    local PREFIX=$1
    echo " --- START REMOTE METRICS ---"
    # Note: We background these on the remote host and store PIDs there
    remote_exec "mkdir -p \$(dirname $PREFIX)"
    remote_exec "iostat -dxm 1 > ${PREFIX}.iostat 2>/dev/null & echo \$! > /tmp/iostat.pid"
    remote_exec "vmstat 1 > ${PREFIX}.vmstat 2>/dev/null & echo \$! > /tmp/vmstat.pid"
    remote_exec "mpstat -P ALL 1 > ${PREFIX}.mpstat 2>/dev/null & echo \$! > /tmp/mpstat.pid"
}

stop_metrics() {
    remote_exec "kill \$(cat /tmp/iostat.pid /tmp/vmstat.pid /tmp/mpstat.pid) 2>/dev/null"
}

init_data() {
  echo ">>> Local Sysbench: Creating tables and inserting data..."
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=16 prepare
}

# --- MAIN EXECUTION ---
stop_container

# Initial run to detect version
run_container
server_wait 

# Detect locally using mysql client pointing to remote host
RAW_VERSION=$(mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -N -e "SELECT VERSION();")
MAJOR_VER=$(echo $RAW_VERSION | cut -d'.' -f1,2)
IS_MARIA=$(echo $RAW_VERSION | grep -i "Maria" | wc -l)
BENCH_DIR="./benchmark_logs"
LOG_DIR="${BENCH_DIR}/${DBMS_NAME}/${RAW_VERSION}"
mkdir -p "$LOG_DIR"

for SIZE in "${POOL_SIZES[@]}"; do
  generate_config $SIZE
  stop_container
  run_container
  server_wait
  init_data
  
  # Warmups (Running Locally)
  sysbench oltp_read_only --mysql-host=$DB_HOST --mysql-user=$DB_USER --mysql-password=$DB_PASS \
    --tables=20 --table-size=$TABLE_ROWS --threads=16 --time=$WARMUP_RO_TIME run
  
  for THREAD in "${THREADS[@]}"; do
      FILE_PREFIX_LOCAL="${LOG_DIR}/Tier${SIZE}G_RW_${THREAD}th"
      # Telemetry file path on remote host
      FILE_PREFIX_REMOTE="${REMOTE_LOG_DIR}/Tier${SIZE}G_RW_${THREAD}th"

      start_metrics "$FILE_PREFIX_REMOTE"

      echo "   >>> Testing $THREAD Threads (Local Sysbench -> Remote DB)..."
      sysbench oltp_read_write \
        --mysql-host=$DB_HOST \
        --mysql-user=$DB_USER \
        --mysql-password=$DB_PASS \
        --tables=20 --table-size=$TABLE_ROWS --threads=$THREAD \
        --time=$DURATION --report-interval=1 \
        run > "${FILE_PREFIX_LOCAL}.sysbench"

      stop_metrics
      
      # Pull metrics back to local for analysis
      scp -q "${REMOTE_HOST}:${FILE_PREFIX_REMOTE}.*" "$LOG_DIR/"
      sleep 15
  done
  stop_container
done
