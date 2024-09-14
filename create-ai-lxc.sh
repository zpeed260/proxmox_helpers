#!/bin/bash

# Function to prompt user for input with validation
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
        echo "Invalid number: $value"
        read -p "Please enter a valid number: " value
    done
    echo "$value"
}

# Function to validate storage selection
validate_storage() {
    local storage_list=$(pvesm status | awk '{print $1}' | grep -v "Name")
    local value="$1"

    while ! echo "$storage_list" | grep -q "^$value$"; do
        echo "Invalid storage: $value"
        echo "Available storage options are:"
        echo "$storage_list"
        read -p "Please enter a valid storage: " value
    done
    echo "$value"
}

# Prompt user for LXC parameters with default values
echo "Welcome to the Proxmox LXC creation script!"

CTID=$(prompt_for_input "Enter LXC container ID" "101")
CTID=$(validate_number "$CTID")

HOSTNAME=$(prompt_for_input "Enter LXC hostname" "ai-lxc")

MEMORY=$(prompt_for_input "Enter memory allocation in MB" "4096")
MEMORY=$(validate_number "$MEMORY")

DISK_SIZE=$(prompt_for_input "Enter disk size (e.g., 16G)" "16G")

CORES=$(prompt_for_input "Enter number of CPU cores" "4")
CORES=$(validate_number "$CORES")

BRIDGE=$(prompt_for_input "Enter network bridge (default: vmbr0)" "vmbr0")

NET_CONFIG=$(prompt_for_input "Enter network configuration (e.g., ip=dhcp)" "ip=dhcp")

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

# Start the LXC container
pct start $CTID

# Wait for container to start
sleep 5

# Install Docker and Docker Compose in the LXC
pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y apt-transport-https ca-certificates curl software-properties-common"
pct exec $CTID -- bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
pct exec $CTID -- bash -c "add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable'"
pct exec $CTID -- bash -c "apt update && apt install -y docker-ce docker-compose"

# Set up Docker Compose for Double Take (skrashevich's fork) and CompreFace with MQTT and Frigate details
pct exec $CTID -- bash -c "mkdir -p /opt/doubletake-compreface && cd /opt/doubletake-compreface"
pct exec $CTID -- bash -c "cat > /opt/doubletake-compreface/docker-compose.yml <<EOF
version: '3.7'

services:
  compreface:
    image: exadel/compreface:latest
    container_name: compreface
    environment:
      - DB_HOST=compreface_db
      - DB_PORT=5432
      - DB_USERNAME=postgres
      - DB_PASSWORD=compreface
      - DB_DATABASE=compreface
      - SERVER_PORT=8000
      - RECREATE_DB=false
      - API_KEY=myapikey
    ports:
      - '8000:8000'
    depends_on:
      - compreface_db
    networks:
      - compreface-net

  compreface_db:
    image: postgres:12
    environment:
      - POSTGRES_DB=compreface
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=compreface
    networks:
      - compreface-net

  double-take:
    image: skrashevich/double-take:latest
    container_name: double-take
    ports:
      - '3000:3000'
    volumes:
      - ./double-take/.storage:/app/.storage
    environment:
      - MQTT_HOST=$MQTT_HOST
      - MQTT_PORT=$MQTT_PORT
      - MQTT_USERNAME=$MQTT_USER
      - MQTT_PASSWORD=$MQTT_PASSWORD
      - DETECTORS=compreface
      - COMPREFACE_URL=http://localhost:8000
      - FRIGATE_URL=$FRIGATE_URL
    depends_on:
      - compreface
    networks:
      - compreface-net

networks:
  compreface-net:
    driver: bridge
EOF"

# Start the Docker services
pct exec $CTID -- bash -c "cd /opt/doubletake-compreface && docker-compose up -d"

# Final confirmation
echo "LXC Container $CTID with Double Take (skrashevich's fork) and CompreFace has been created and is running."
echo "Double Take is configured to connect to MQTT at $MQTT_HOST and Frigate at $FRIGATE_URL."
