#!/bin/bash

sudo apt update
sudo apt install docker.io sysstat sysbench mysql-client dstat -y

./run_pt_summary.sh
./run_pt_mysql_summary.sh

IS_READ_ONLY="$1"

VERSIONS=("5.7" "8.0" "8.4")
for VERSION in "${VERSIONS[@]}"; do
  ./run_metrics.sh "percona-server" "$VERSION" "$IS_READ_ONLY"
done

VERSIONS=("5.7" "8.0" "8.4" "9.6")

for VERSION in "${VERSIONS[@]}"; do
  ./run_metrics.sh "mysql" "$VERSION" "$IS_READ_ONLY"
done

VERSIONS=("10.11" "11.4" "12.1")

for VERSION in "${VERSIONS[@]}"; do
  ./run_metrics.sh "mariadb" "$VERSION" "$IS_READ_ONLY"
done

echo "All benchmarks completed!"