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

# Create LXC container with Proxmox defaults
create_lxc_container() {
    local CTID=$1
    local MEMORY=4096  # 4GB RAM
    local CORES=4      # 4 CPU cores
    local DISK_SIZE=16G
    local STORAGE="local-lvm"
    local HOSTNAME="ai-lxc-${CTID}"
    local BRIDGE="vmbr0"
    local NET_CONFIG="ip=dhcp"

    msg_info "Creating LXC container with ID $CTID..."

    retry_command pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
        --hostname $HOSTNAME --memory $MEMORY --cores $CORES \
        --rootfs ${STORAGE}:${DISK_SIZE} --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1
    
    if [[ $? -ne 0 ]]; then
        msg_error "Container creation failed!"
        exit 1
    fi

    msg_ok "LXC container $CTID created successfully."
}

# Install Docker and Docker Compose inside the LXC container
install_docker_in_lxc() {
    local CTID=$1
    msg_info "Installing Docker inside LXC $CTID..."

    retry_command pct exec $CTID -- bash -c "apt update && apt upgrade -y"
    retry_command pct exec $CTID -- bash -c "apt install -y apt-transport-https ca-certificates curl software-properties-common"
    retry_command pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
    retry_command pct exec $CTID -- bash -c "add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable'"
    retry_command pct exec $CTID -- bash -c "apt update && apt install -y docker-ce docker-compose"
    
    msg_ok "Docker installed successfully inside LXC $CTID."
}

# Setup Docker Compose for Double Take and CompreFace
setup_doubletake_compreface() {
    local CTID=$1
    msg_info "Setting up Docker Compose for Double Take and CompreFace inside LXC $CTID..."

    retry_command pct exec $CTID -- bash -c "mkdir -p /opt/double-take"
    retry_command pct exec $CTID -- bash -c "mkdir -p /opt/compreface"

    # Create Docker Compose for Double Take and CompreFace
    pct exec $CTID -- bash -c 'cat <<EOF > /opt/double-take/docker-compose.yml
version: "3"
services:
  double-take:
    container_name: double-take
    image: jakowenko/double-take
    ports:
      - 3000:3000
    volumes:
      - ./config:/app/config
    restart: always

  compreface:
    container_name: compreface
    image: exadel/compreface
    ports:
      - 8000:80
    restart: always
EOF'

    # Start Docker Compose
    retry_command pct exec $CTID -- bash -c "cd /opt/double-take && docker-compose up -d"

    msg_ok "Double Take and CompreFace setup completed inside LXC $CTID."
}

# Main execution flow
main() {
    local CTID=$(get_next_lxc_id)

    # Ensure the container ID does not exist
    check_ct_exists "$CTID"

    # Create the LXC container
    create_lxc_container "$CTID"

    # Install Docker inside the container
    install_docker_in_lxc "$CTID"

    # Setup Double Take and CompreFace inside the container
    setup_doubletake_compreface "$CTID"

    msg_ok "LXC container with ID $CTID has been set up with Double Take and CompreFace!"
}

# Run the main function
main
