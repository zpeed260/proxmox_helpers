#!/bin/bash

# Define utility functions for logging and retries

msg_info() {
    echo -e "\e[1;33m[INFO]\e[0m $1"
}

msg_ok() {
    echo -e "\e[1;32m[OK]\e[0m $1"
}

msg_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1"
}

retry_command() {
    local retries=5
    local delay=10
    local success=0
    for ((i=0; i<$retries; i++)); do
        "$@" && success=1 && break
        msg_info "Retry $((i + 1))/$retries failed. Retrying in $delay seconds..."
        sleep $delay
    done
    if [[ $success -eq 0 ]]; then
        msg_error "Command failed after $retries attempts."
        exit 1
    fi
}

# Function to get the next available LXC container ID
get_next_lxc_id() {
    local last_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
    local next_id=$((last_id + 1))
    echo "$next_id"
}

# Check if container ID already exists
check_ct_exists() {
    if pct list | grep -qw "^$1"; then
        msg_error "Container ID $1 already exists!"
        exit 1
    fi
}

# List available storage options and let the user select
select_storage() {
    local storages=$(pvesm status | awk 'NR>1 {print $1}')
    echo "Available storage options:"
    echo "$storages"
    read -p "Enter the storage to use for the LXC container (e.g., local-lvm, data): " selected_storage
    echo "$selected_storage"
}

# Create LXC container with default settings
create_lxc_container() {
    local CTID=$1
    local MEMORY=4096  # 4GB RAM
    local CORES=4      # 4 CPU cores
    local DISK_SIZE=16G
    local STORAGE=$2
    local HOSTNAME="ai-lxc-${CTID}"
    local BRIDGE="vmbr0"
    local NET_CONFIG="ip=dhcp"

    msg_info "Creating LXC container with ID $CTID on storage $STORAGE..."

    retry_command pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst --rootfs ${STORAGE}:${DISK_SIZE} --hostname $HOSTNAME --memory $MEMORY --cores $CORES --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1
    
    if [[ $? -ne 0 ]]; then
        msg_error "
