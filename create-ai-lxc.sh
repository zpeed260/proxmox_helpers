#!/bin/bash

# Function definitions from build.func

msg_info() {
    echo -e "\e[1;33m[INFO]\e[0m $1"
}

msg_ok() {
    echo -e "\e[1;32m[OK]\e[0m $1"
}

msg_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1"
}

# Retry function for operations
retry_command() {
    local retries=5
    local delay=5
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

# Function to check if container ID already exists
check_ct_exists() {
    if pct list | grep -qw "^$1"; then
        msg_error "Container ID $1 already exists!"
        exit 1
    fi
}

# Function to download LXC templates
download_template() {
    msg_info "Downloading Ubuntu LXC template..."
    retry_command pveam update
    retry_command pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
    msg_ok "Template downloaded."
}

# Centralized function to create an LXC container
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

# Function to start the LXC container
start_lxc_container() {
    local CTID=$1
    msg_info "Starting LXC container $CTID..."
    retry_command pct start $CTID
    msg_ok "LXC container $CTID started successfully."
}

# Function to install Docker inside the LXC
install_docker() {
    local CTID=$1
    msg_info "Installing Docker inside LXC $CTID..."
    retry_command pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y apt-transport-https ca-certificates curl software-properties-common"
    retry_command pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
    retry_command pct exec $CTID -- bash -c "add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable'"
    retry_command pct exec $CTID -- bash -c "apt update && apt install -y docker-ce docker-compose"
    msg_ok "Docker installed successfully in LXC $CTID."
}

# Function to prompt user for input with pre-filled default values
prompt_for_input() {
    local prompt_message="$1"
    local default_value="$2"
    local user_input

    read -p "$prompt_message ($default_value): " user_input
    echo "${user_input:-$default_value}"
}

# Get the next available LXC container ID
get_next_lxc_id() {
    local last_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
    local next_id=$((last_id + 1))
    echo "$next_id"
}

# Main script execution
main() {
    # Prompt user for inputs (same logic from earlier)
    local CTID=$(get_next_lxc_id)
    CTID=$(prompt_for_input "Enter LXC container ID" "$CTID")
    check_ct_exists "$CTID"

    local HOSTNAME=$(prompt_for_input "Enter LXC hostname" "ai-lxc")
    local MEMORY=$(prompt_for_input "Enter memory allocation in MB" "4096")
    local DISK_SIZE=$(prompt_for_input "Enter disk size (e.g., 16G)" "16G")
    local CORES=$(prompt_for_input "Enter number of CPU cores" "4")
    local STORAGE=$(prompt_for_input "Enter storage location" "local-lvm")
    local BRIDGE=$(prompt_for_input "Enter network bridge" "vmbr0")
    local NET_CONFIG=$(prompt_for_input "Enter network configuration (e.g., ip=dhcp)" "ip=dhcp")

    # Download the LXC template
    download_template

    # Create the container
    create_lxc_container "$CTID" "$HOSTNAME" "$MEMORY" "$CORES" "$DISK_SIZE" "$STORAGE" "$BRIDGE" "$NET_CONFIG"

    # Start the container
    start_lxc_container "$CTID"

    # Install Docker
    install_docker "$CTID"
}

# Execute the main function
main
