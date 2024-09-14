#!/bin/bash

# Define utility functions for output formatting
msg_info() {
    echo -e "\e[1;33m[INFO]\e[0m $1"
}

msg_ok() {
    echo -e "\e[1;32m[OK]\e[0m $1"
}

msg_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1"
}

# Function to check if container ID already exists
check_lxc_exists() {
    if pct list | grep -qw "^$1"; then
        msg_error "Container ID $1 already exists!"
        exit 1
    fi
}

# Function to retry commands
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

# Prompt user for input with pre-filled default values
prompt_for_input() {
    local prompt_message="$1"
    local default_value="$2"
    local user_input

    read -p "$prompt_message ($default_value): " user_input
    echo "${user_input:-$default_value}"
}

# Get next available LXC container ID
get_next_lxc_id() {
    local last_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
    local next_id=$((last_id + 1))
    echo "$next_id"
}

# Confirm function that accepts yes, y, or no
confirm_action() {
    local prompt_message="$1"
    local confirm

    read -p "$prompt_message (yes/y/no): " confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')  # Convert input to lowercase
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        msg_info "Action aborted by the user."
        exit 1
    fi
}

# Get the next available LXC container ID
CTID=$(get_next_lxc_id)

msg_info "Welcome to the Proxmox LXC creation script!"

# Check if the container ID is already used
check_lxc_exists "$CTID"

# Prompt user for LXC parameters with validation
CTID=$(prompt_for_input "Enter LXC container ID" "$CTID")

HOSTNAME=$(prompt_for_input "Enter LXC hostname" "ai-lxc")

MEMORY=$(prompt_for_input "Enter memory allocation in MB" "4096")

DISK_SIZE=$(prompt_for_input "Enter disk size (e.g., 16G)" "16G")

CORES=$(prompt_for_input "Enter number of CPU cores" "4")

BRIDGE=$(prompt_for_input "Enter network bridge (default: vmbr0)" "vmbr0")

NET_CONFIG=$(prompt_for_input "Enter network configuration (e.g., ip=dhcp)" "ip=dhcp")

STORAGE=$(prompt_for_input "Enter storage location" "local-lvm")

MQTT_HOST=$(prompt_for_input "Enter MQTT Host IP" "192.168.1.100")
MQTT_PORT=$(prompt_for_input "Enter MQTT Port" "1883")
MQTT_USER=$(prompt_for_input "Enter MQTT Username" "mqtt_user")
MQTT_PASSWORD=$(prompt_for_input "Enter MQTT Password" "mqtt_password")

FRIGATE_URL=$(prompt_for_input "Enter Frigate URL (e.g., http://192.168.1.200:5000)" "http://192.168.1.200:5000")

msg_info "Summary of LXC configuration:"
msg_info "Container ID: $CTID"
msg_info "Hostname: $HOSTNAME"
msg_info "Memory: $MEMORY MB"
msg_info "Disk Size: $DISK_SIZE"
msg_info "Cores: $CORES"
msg_info "Bridge: $BRIDGE"
msg_info "Network Config: $NET_CONFIG"
msg_info "Storage: $STORAGE"
msg_info "MQTT Host: $MQTT_HOST"
msg_info "MQTT Port: $MQTT_PORT"
msg_info "MQTT User: $MQTT_USER"
msg_info "Frigate URL: $FRIGATE_URL"

# Confirm the configuration
confirm_action "Proceed with LXC creation?"

# Create the LXC container
msg_info "Creating LXC container..."
retry_command pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst --storage $STORAGE --hostname $HOSTNAME --rootfs $DISK_SIZE --memory $MEMORY --cores $CORES --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1
msg_ok "LXC container created successfully."

# Start the LXC container
msg_info "Starting LXC container $CTID..."
retry_command pct start $CTID
msg_ok "LXC container started successfully."

# Further steps for Docker installation and setup
msg_info "Installing Docker in LXC $CTID..."
retry_command pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y apt-transport-https ca-certificates curl software-properties-common"
retry_command pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
retry_command pct exec $CTID -- bash -c "add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable'"
retry_command pct exec $CTID -- bash -c "apt update && apt install -y docker-ce docker-compose"
msg_ok "Docker installed successfully in LXC $CTID."

# Rest of the script logic...

