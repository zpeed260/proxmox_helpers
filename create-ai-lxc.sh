#!/bin/bash

# Simplified message functions for feedback
msg_info() { echo -e "\e[1;33m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[1;32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[1;31m[ERROR]\e[0m $1"; }

# Retry function with longer delay
retry_command() {
    local retries=3
    local delay=10
    for ((i=0; i<$retries; i++)); do
        "$@" && return 0
        echo "Retry $((i + 1))/$retries failed. Retrying in $delay seconds..."
        sleep $delay
    done
    msg_error "Command failed after $retries attempts."
    exit 1
}

# Create LXC Container
create_lxc_container() {
    local CTID=$1
    local HOSTNAME=$2
    local MEMORY=$3
    local CORES=$4
    local DISK_SIZE=$5
    local STORAGE=$6
    local BRIDGE=$7
    local NET_CONFIG=$8

    msg_info "Creating LXC container..."
    retry_command pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
        --hostname $HOSTNAME --storage $STORAGE --memory $MEMORY --cores $CORES \
        --rootfs $DISK_SIZE --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1
    msg_ok "LXC container $CTID created successfully."
}

# Start LXC container
start_lxc_container() {
    local CTID=$1
    msg_info "Starting LXC container $CTID..."
    retry_command pct start $CTID
    msg_ok "LXC container $CTID started successfully."
}

# Install Docker inside the LXC
install_docker() {
    local CTID=$1
    msg_info "Installing Docker inside LXC $CTID..."
    retry_command pct exec $CTID -- bash -c "apt update && apt install -y docker-ce docker-compose"
    msg_ok "Docker installed successfully in LXC $CTID."
}

# Main Script Logic
main() {
    local CTID=101  # Example CTID, replace with logic to find next available
    local HOSTNAME="ai-lxc"
    local MEMORY="2048"
    local CORES="2"
    local DISK_SIZE="8G"
    local STORAGE="local-lvm"
    local BRIDGE="vmbr0"
    local NET_CONFIG="ip=dhcp"

    create_lxc_container "$CTID" "$HOSTNAME" "$MEMORY" "$CORES" "$DISK_SIZE" "$STORAGE" "$BRIDGE" "$NET_CONFIG"
    start_lxc_container "$CTID"
    install_docker "$CTID"
}

main
