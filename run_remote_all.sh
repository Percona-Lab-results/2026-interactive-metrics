#!/bin/bash

sudo apt update
sudo apt install docker.io sysstat sysbench mysql-client  -y

# NOTE: The script assumes that the remote servers
#       are configured to allow SSH access using the
#       provided private key and that the necessary
#       permissions are set up for the user running the script.

eval "$(ssh-agent -s)"
# Add the private key to the SSH agent
key_path="$1"

if [ -f "$key_path" ]; then
    ssh-add "$key_path"
else 
    echo "Error: SSH private key not found at '$key_path'. Please provide a valid path to the SSH private key as an argument."
    exit 1
fi

./run_pt_mysql_summary.sh

VERSIONS=("5.7" "8.0" "8.4")
for VERSION in "${VERSIONS[@]}"; do
  ./run_remote_metrics.sh "percona-server" "$VERSION"
done

VERSIONS=("10.11" "11.4" "12.1")
for VERSION in "${VERSIONS[@]}"; do
  ./run_remote_metrics.sh "mariadb" "$VERSION"
done

VERSIONS=("5.7" "8.0" "8.4" "9.6")

for VERSION in "${VERSIONS[@]}"; do
  ./run_remote_metrics.sh "mysql" "$VERSION"
done

echo "All benchmarks completed!"
