#!/bin/bash

sudo apt update
sudo apt install docker.io sysstat sysbench mysql-client  -y

VERSIONS=("5.7" "8.0" "8.4")

for VERSION in "${VERSIONS[@]}"; do
  ./run_finch_metrics.sh "percona-server" "$VERSION"
  echo ""
done

VERSIONS=("10.11" "11.4" "12.1")

for VERSION in "${VERSIONS[@]}"; do
  ./run_finch_metrics.sh "mariadb" "$VERSION"
  echo ""
done

VERSIONS=("5.7" "8.0" "8.4" "9.6")

for VERSION in "${VERSIONS[@]}"; do
  ./run_finch_metrics.sh "mysql" "$VERSION"
  echo ""
done

echo "All benchmarks completed!"
