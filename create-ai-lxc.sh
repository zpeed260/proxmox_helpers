#!/bin/bash

# Function to prompt user for input with pre-filled default values
prompt_for_input() {
    local prompt_message="$1"
    local default_value="$2"
    local user_input

    read -p "$prompt_message ($default_value): " user_input
    echo "${user_input:-$default_value}"
}

# Function to validate a number
validate_number() {
    local value="$1"
    while ! [[ "$value" =~ ^[0-9]+$ ]]; do
        echo "Invalid number: $value. Please enter a valid number."
        read -p "Please enter a valid number: " value
    done
    echo "$value"
}

# Function to validate LXC ID (must be unique and numeric)
validate_lxc_id() {
    local value="$1"
    while ! [[ "$value" =~ ^[0-9]+$ ]] || pct list | awk '{print $1}' | grep -q "^$value$"; do
        echo "Invalid or existing LXC ID: $value. Please enter a valid, unique LXC ID."
        read -p "Please enter a valid LXC ID: " value
    done
    echo "$value"
}

# Function to validate hostname (RFC 1123 compliant)
validate_hostname() {
    local value="$1"
    while ! [[ "$value" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*[a-zA-Z0-9]$ ]] || [[ ${#value} -gt 63 ]]; do
        echo "Invalid hostname: $value. Hostname must be alphanumeric and between 1-63 characters."
        read -p "Please enter a valid hostname: " value
    done
    echo "$value"
}

# Function to validate memory allocation
validate_memory() {
    local value="$1"
    while ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 256 ]]; do
        echo "Invalid memory: $value. Minimum memory allocation is 256MB."
        read -p "Please enter a valid memory allocation (MB): " value
    done
    echo "$value"
}

# Function to validate disk size (must end with G or M)
validate_disk_size() {
    local value="$1"
    while ! [[ "$value" =~ ^[0-9]+[GM]$ ]]; do
        echo "Invalid disk size: $value. Enter a size followed by G (GB) or M (MB)."
        read -p "Please enter a valid disk size (e.g., 16G): " value
    done
    echo "$value"
}

# Function to validate number of cores (minimum 1)
validate_cores() {
    local value="$1"
    while ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; do
        echo "Invalid core count: $value. The number of cores must be at least 1."
        read -p "Please enter a valid number of CPU cores: " value
    done
    echo "$value"
}

# Function to validate network bridge
validate_network_bridge() {
    local value="$1"
    local bridges=$(grep -oP '(?<=^auto\s)\w+' /etc/network/interfaces)
    while ! echo "$bridges" | grep -q "^$value$"; do
        echo "Invalid network bridge: $value. Available bridges are:"
        echo "$bridges"
        read -p "Please enter a valid network bridge: " value
    done
    echo "$value"
}

# Function to validate network configuration (e.g., DHCP, IP=...)
validate_network_config() {
    local value="$1"
    while ! [[ "$value" =~ ^(dhcp|ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/24)$ ]]; do
        echo "Invalid network configuration: $value. Use 'dhcp' or 'ip=<IP Address>/24' format."
        read -p "Please enter a valid network configuration: " value
    done
    echo "$value"
}

# Function to validate storage selection
validate_storage() {
    local storage_list=$(pvesm status | awk '{print $1}' | grep -v "Name")
    local value="$1"
    while ! echo "$storage_list" | grep -q "^$value$"; do
        echo "Invalid storage: $value. Available storage options are:"
        echo "$storage_list"
        read -p "Please enter a valid storage: " value
    done
    echo "$value"
}

# Find next available LXC ID
get_next_lxc_id() {
    local last_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
    local next_id=$((last_id + 1))
    echo "$next_id"
}

# Get the next available LXC container ID
CTID=$(get_next_lxc_id)

# Prompt user for LXC parameters with validation
echo "Welcome to the Proxmox LXC creation script!"

CTID=$(prompt_for_input "Enter LXC container ID" "$CTID")
CTID=$(validate_lxc_id "$CTID")

HOSTNAME=$(prompt_for_input "Enter LXC hostname" "ai-lxc")
HOSTNAME=$(validate_hostname "$HOSTNAME")

MEMORY=$(prompt_for_input "Enter memory allocation in MB" "4096")
MEMORY=$(validate_memory "$MEMORY")

DISK_SIZE=$(prompt_for_input "Enter disk size (e.g., 16G)" "16G")
DISK_SIZE=$(validate_disk_size "$DISK_SIZE")

CORES=$(prompt_for_input "Enter number of CPU cores" "4")
CORES=$(validate_cores "$CORES")

BRIDGE=$(prompt_for_input "Enter network bridge (default: vmbr0)" "vmbr0")
BRIDGE=$(validate_network_bridge "$BRIDGE")

NET_CONFIG=$(prompt_for_input "Enter network configuration (e.g., ip=dhcp)" "ip=dhcp")
NET_CONFIG=$(validate_network_config "$NET_CONFIG")

# Validate storage
STORAGE=$(prompt_for_input "Enter storage location (use pvesm status to check)" "local-lvm")
STORAGE=$(validate_storage "$STORAGE")

# Prompt for MQTT details
echo ""
echo "Please provide MQTT details for Double Take configuration:"
MQTT_HOST=$(prompt_for_input "Enter MQTT Host IP" "192.168.1.100")
MQTT_PORT=$(prompt_for_input "Enter MQTT Port" "1883")
MQTT_USER=$(prompt_for_input "Enter MQTT Username" "mqtt_user")
MQTT_PASSWORD=$(prompt_for_input "Enter MQTT Password" "mqtt_password")

# Prompt for Frigate details
echo ""
echo "Please provide Frigate details for Double Take configuration:"
FRIGATE_URL=$(prompt_for_input "Enter Frigate URL (e.g., http://192.168.1.200:5000)" "http://192.168.1.200:5000")

# Confirm the parameters
echo ""
echo "Summary of LXC configuration:"
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Memory: $MEMORY MB"
echo "Disk Size: $DISK_SIZE"
echo "Cores: $CORES"
echo "Bridge: $BRIDGE"
echo "Network Config: $NET_CONFIG"
echo "Storage: $STORAGE"
echo "MQTT Host: $MQTT_HOST"
echo "MQTT Port: $MQTT_PORT"
echo "MQTT User: $MQTT_USER"
echo "Frigate URL: $FRIGATE_URL"
echo ""

# Ask for confirmation before proceeding
read -p "Proceed with LXC creation (yes/no)? " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "LXC creation aborted."
    exit 1
fi

# Create the LXC container
echo "Creating LXC container..."
pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst --storage $STORAGE --hostname $HOSTNAME --rootfs $DISK_SIZE --memory $MEMORY --cores $CORES --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1

# Further steps go here...

