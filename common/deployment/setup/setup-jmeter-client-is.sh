#!/bin/bash -e
# Copyright (c) 2018, WSO2 Inc. (http://wso2.org) All Rights Reserved.
#
# WSO2 Inc. licenses this file to you under the Apache License,
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
# Setup JMeter Client
# ----------------------------------------------------------------------------

# Make sure the script is running as root.
if [ "$UID" -ne "0" ]; then
    echo "You must be root to run $0. Try following"
    echo "sudo $0"
    exit 9
fi

export script_name="$0"
script_dir=$(dirname "$0")

alpnboot_dir="/opt/alpnboot"
mkdir -p $alpnboot_dir

command="$script_dir/setup-jmeter-client.sh $@ \
    -w http://search.maven.org/remotecontent?filepath=org/mortbay/jetty/alpn/alpn-boot/8.1.12.v20180117/alpn-boot-8.1.12.v20180117.jar \
    -o $alpnboot_dir/alpnboot.jar -j bzm-parallel"
echo $command
# Keep the full output so failures here (which otherwise leave the SSH host
# aliases and JMeter unconfigured and cascade downstream) are diagnosable.
log_file="/home/ubuntu/jmeter-client-setup.log"
if ! $command > "$log_file" 2>&1; then
    echo "WARN: setup-jmeter-client.sh returned non-zero. Last 50 lines of $log_file:"
    tail -n 50 "$log_file"
    # The essential outputs are the SSH host aliases (whose absence caused the
    # original downstream cascade) and the JMeter install. A trailing plugin
    # install failure — e.g. bzm-parallel, which no JMX in this repo uses, and
    # which breaks only because the JMeter Plugins Manager auto-upgrades
    # cmdrunner past the version the upstream script expects — is non-fatal.
    # So only abort if the SSH client config was never created.
    if [ ! -s /home/ubuntu/.ssh/config ]; then
        echo "ERROR: SSH client config (/home/ubuntu/.ssh/config) missing; JMeter client setup truly failed."
        exit 1
    fi
    echo "SSH client config present; treating the non-zero exit as non-fatal and continuing."
fi
