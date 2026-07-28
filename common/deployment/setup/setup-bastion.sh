#!/usr/bin/env bash
# Copyright (c) 2019, wso2 Inc. (http://wso2.org) All Rights Reserved.
#
# wso2 Inc. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# ----------------------------------------------------------------------------
# Setup the bastion node to be used as the JMeter client.
# ----------------------------------------------------------------------------

no_of_nodes=""
wso2_is_1_ip=""
wso2_is_2_ip=""
wso2_is_3_ip=""
wso2_is_4_ip=""
lb_host=""
rds_host=""
session_rds_host=""
wso2is_1_host_alias=wso2is1
wso2is_2_host_alias=wso2is2
wso2is_3_host_alias=wso2is3
wso2is_4_host_alias=wso2is4
lb_alias=loadbalancer

function usage() {
    echo ""
    echo "Usage: "
    echo "$0 -w <wso2_is_1_ip> -i <wso2_is_2_ip> -l <lb_host> -r <rds_host> -s <session_rds_host>"
    echo ""
    echo "-w: The private IP of WSO2 IS node 1."
    echo "-i: The private IP of WSO2 IS node 2."
    echo "-j: The private IP of WSO2 IS node 3."
    echo "-k: The private IP of WSO2 IS node 4."
    echo "-l: The private hostname of Load balancer instance."
    echo "-r: The private hostname of RDS instance."
    echo "-s: The private hostname of the session Database RDS instance."
    echo "-h: Display this help and exit."
    echo ""
}

while getopts "n:w:i:j:k:l:r:s:h" opts; do
    case $opts in
    n)
        no_of_nodes=${OPTARG}
        ;;
    w)
        wso2_is_1_ip=${OPTARG}
        ;;
    i)
        wso2_is_2_ip=${OPTARG}
        ;;
    j)
        wso2_is_3_ip=${OPTARG}
        ;;
    k)
        wso2_is_4_ip=${OPTARG}
        ;;
    l)
        lb_host=${OPTARG}
        ;;
    r)
        rds_host=${OPTARG}
        ;;
    s)
        session_rds_host=${OPTARG}
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        usage
        exit 1
        ;;
    esac
done

if [[ -z $lb_host ]]; then
    echo "Please provide the private hostname of Load balancer instance."
    exit 1
fi

if [[ -z $rds_host ]]; then
    echo "Please provide the private hostname of the RDS instance."
    exit 1
fi

if [[ -z $session_rds_host ]]; then
    echo "Please provide the private hostname of the session Database RDS instance."
    exit 1
fi

function get_ssh_hostname() {
    sudo -u ubuntu ssh -G "$1" | awk '/^hostname / { print $2 }'
}

echo ""
echo "Ensuring bastion prerequisites are installed..."
echo "============================================"
# The bastion can run this setup before cloud-init has finished its own apt
# work, leaving the dpkg lock held and core tools (unzip, zip, jq, mysql)
# missing. When that happens the whole run cascades into "command not found"
# and "could not resolve hostname" failures. Wait for apt to settle, then
# install what the rest of the pipeline needs, and fail fast if it can't.
export DEBIAN_FRONTEND=noninteractive

# 1. Wait for cloud-init to finish (best effort; not every AMI ships it).
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait || true
fi

# 2. Wait (max ~5 min) for any apt/dpkg lock to be released.
for i in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 &&
        ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        break
    fi
    echo "Waiting for apt/dpkg lock to be released... ($i)"
    sleep 5
done

# 3. Install prerequisites, retrying transient mirror/network hiccups.
#    apt-get update is best-effort: the bastion adds custom MS/nginx apt
#    repos that can make it exit non-zero, but unzip/zip/jq come from the
#    default Ubuntu repos, so a flaky third-party repo must not block them.
for attempt in 1 2 3; do
    apt-get update -y || true
    apt-get install -y unzip zip jq && break
    echo "apt install attempt $attempt failed; retrying in 15s..."
    sleep 15
done

# mysql client package name varies across Ubuntu releases; try the common ones.
if ! command -v mysql >/dev/null 2>&1; then
    apt-get install -y mysql-client ||
        apt-get install -y mysql-client-core-8.0 ||
        apt-get install -y mariadb-client || true
fi

# 4. Fail fast (with a clear message) if anything is still missing, instead of
#    cascading through 15 minutes of doomed downstream steps.
missing=()
for cmd in unzip zip jq mysql; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: required commands still missing after bastion setup: ${missing[*]}"
    exit 1
fi

echo ""
echo "Setting up required files..."
echo "============================================"
cd /home/ubuntu || exit 0
mkdir workspace
cd workspace || exit 0

echo ""
echo "Extracting is performance distribution..."
echo "============================================"
tar -C /home/ubuntu/workspace -xzf /home/ubuntu/is-performance-*.tar.gz

echo ""
echo "Sanitizing JMeter tarball (strip macOS AppleDouble metadata)..."
echo "============================================"
# The apache-jmeter tarball in the resources bucket is packed on macOS and
# carries AppleDouble entries (._apache-jmeter-*) plus com.apple.quarantine
# xattrs. setup-jmeter-client.sh takes the first tar entry as JMeter home and
# lands on the "._apache-jmeter-*" metadata file (not a directory), so the
# user.properties copy fails. Repack cleanly so only apache-jmeter-*/ remains.
jm_tgz=$(ls /home/ubuntu/apache-jmeter-*.tgz 2>/dev/null | head -1)
if [[ -n $jm_tgz ]]; then
    jm_tmp=$(mktemp -d)
    if tar -xzf "$jm_tgz" -C "$jm_tmp" 2>/dev/null; then
        find "$jm_tmp" -name '._*' -delete
        jm_dir=$(find "$jm_tmp" -maxdepth 1 -mindepth 1 -type d -name 'apache-jmeter-*' | head -1)
        if [[ -n $jm_dir ]]; then
            (cd "$jm_tmp" && tar -czf "$jm_tgz" "$(basename "$jm_dir")")
            echo "Repacked $(basename "$jm_tgz") as clean $(basename "$jm_dir")"
        fi
    fi
    rm -rf "$jm_tmp"
fi

echo ""
echo "Running JMeter setup script..."
echo "============================================"
cd /home/ubuntu || exit 0

if [[ -z $no_of_nodes ]]; then
    echo "Please provide the number of IS nodes in the deployment."
    exit 1
elif [[ $no_of_nodes -eq 1 ]]; then
    workspace/setup/setup-jmeter-client-is.sh -g -k /home/ubuntu/private_key.pem \
                -i /home/ubuntu \
                -c /home/ubuntu \
                -f /home/ubuntu/apache-jmeter-*.tgz \
                -a $wso2is_1_host_alias -n "$wso2_is_1_ip" \
                -a $lb_alias -n "$lb_host"\
                -a rds -n "$rds_host"\
                -a sessionrds -n "$session_rds_host"
elif [[ $no_of_nodes -eq 2 ]]; then
    workspace/setup/setup-jmeter-client-is.sh -g -k /home/ubuntu/private_key.pem \
                -i /home/ubuntu \
                -c /home/ubuntu \
                -f /home/ubuntu/apache-jmeter-*.tgz \
                -a $wso2is_1_host_alias -n "$wso2_is_1_ip" \
                -a $wso2is_2_host_alias -n "$wso2_is_2_ip" \
                -a $lb_alias -n "$lb_host"\
                -a rds -n "$rds_host"\
                -a sessionrds -n "$session_rds_host"
elif [[ $no_of_nodes -eq 3 ]]; then
    workspace/setup/setup-jmeter-client-is.sh -g -k /home/ubuntu/private_key.pem \
                -i /home/ubuntu \
                -c /home/ubuntu \
                -f /home/ubuntu/apache-jmeter-*.tgz \
                -a $wso2is_1_host_alias -n "$wso2_is_1_ip" \
                -a $wso2is_2_host_alias -n "$wso2_is_2_ip" \
                -a $wso2is_3_host_alias -n "$wso2_is_3_ip" \
                -a $lb_alias -n "$lb_host"\
                -a rds -n "$rds_host"\
                -a sessionrds -n "$session_rds_host"
elif [[ $no_of_nodes -eq 4 ]]; then
    workspace/setup/setup-jmeter-client-is.sh -g -k /home/ubuntu/private_key.pem \
                -i /home/ubuntu \
                -c /home/ubuntu \
                -f /home/ubuntu/apache-jmeter-*.tgz \
                -a $wso2is_1_host_alias -n "$wso2_is_1_ip" \
                -a $wso2is_2_host_alias -n "$wso2_is_2_ip" \
                -a $wso2is_3_host_alias -n "$wso2_is_3_ip" \
                -a $wso2is_4_host_alias -n "$wso2_is_4_ip" \
                -a $lb_alias -n "$lb_host"\
                -a rds -n "$rds_host"\
                -a sessionrds -n "$session_rds_host"
else
    echo "Invalid value for no_of_nodes. Please provide a valid number."
    exit 1
fi

sudo chown -R ubuntu:ubuntu workspace
sudo chown -R ubuntu:ubuntu apache-jmeter-*
sudo chown -R ubuntu:ubuntu /tmp/jmeter.log
sudo chown -R ubuntu:ubuntu jmeter.log

echo ""
echo "Coping files to NGinx instance..."
echo "============================================"
sudo -u ubuntu scp -r /home/ubuntu/workspace/setup/resources/ $lb_alias:/home/ubuntu/
sudo -u ubuntu scp /home/ubuntu/workspace/setup/setup-nginx.sh $lb_alias:/home/ubuntu/

echo ""
echo "Setting up NGinx..."
echo "============================================"

if [[ $no_of_nodes -eq 1 ]]; then
    sudo -u ubuntu ssh $lb_alias ./setup-nginx.sh -n "$no_of_nodes" -i "$wso2_is_1_ip"
elif [[ $no_of_nodes -eq 2 ]]; then
    sudo -u ubuntu ssh $lb_alias ./setup-nginx.sh -n "$no_of_nodes" -i "$wso2_is_1_ip" -w "$wso2_is_2_ip"
elif [[ $no_of_nodes -eq 3 ]]; then
    sudo -u ubuntu ssh $lb_alias ./setup-nginx.sh -n "$no_of_nodes" -i "$wso2_is_1_ip" -w "$wso2_is_2_ip" -j "$wso2_is_3_ip"
elif [[ $no_of_nodes -eq 4 ]]; then
    sudo -u ubuntu ssh $lb_alias ./setup-nginx.sh -n "$no_of_nodes" -i "$wso2_is_1_ip" -w "$wso2_is_2_ip" -j "$wso2_is_3_ip" -k "$wso2_is_4_ip"
fi

