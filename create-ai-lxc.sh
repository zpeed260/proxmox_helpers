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

# Check available free space in the LVM group or thin pool
check_lvm_space() {
    local VG=$1
    local REQUIRED_SPACE=$2
    local LVTYPE=$3

    # Check space based on LVM type
    if [ "$LVTYPE" == "thin" ]; then
        # For LVM-thin, check the thin pool size
        local FREE_SPACE=$(lvs --noheadings -o size,free --units G | grep "$VG" | awk '{print $2}' | sed 's/G//')
    else
        # For traditional LVM, check the volume group free space
        local FREE_SPACE=$(vgs --noheadings -o vg_free --units G | grep "$VG" | sed 's/G//')
    fi

    if [[ -z "$FREE_SPACE" ]]; then
        msg_error "Unable to retrieve available space for VG $VG."
        exit 1
    fi

    if (( $(echo "$REQUIRED_SPACE > $FREE_SPACE" | bc -l) )); then
        msg_error "Requested disk size (${REQUIRED_SPACE}G) exceeds available space (${FREE_SPACE}G) in VG $VG."
        exit 1
    fi

    msg_ok "Sufficient free space (${FREE_SPACE}G) available in VG $VG."
}

# Create LXC container with given configuration
create_lxc_container() {
    local CTID=$1
    local HOSTNAME=$2
    local MEMORY=$3
    local CORES=$4
    local DISK_SIZE=$5
    local STORAGE=$6
    local BRIDGE=$7
    local NET_CONFIG=$8
    local VG="pve" # Change if you're using a different volume group

    msg_info "Creating LXC container with ID $CTID..."

    # Ensure the rootfs storage uses the correct format STORAGE:SIZE
    retry_command pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
        --hostname $HOSTNAME --memory $MEMORY --cores $CORES \
        --rootfs ${STORAGE}:${DISK_SIZE} --net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG --features nesting=1 --unprivileged 1
    
    if [[ $? -ne 0 ]]; then
        msg_error "Container creation failed!"
        exit 1
    fi

    msg_ok "LXC container $CTID created successfully."
}

# Check if container ID already exists
check_ct_exists() {
    if pct list | grep -qw "^$1"; then
        msg_error "Container ID $1 already exists!"
        exit 1
    fi
}

# Main execution flow
main() {
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
    local LVTYPE="thin" # Set to "lvm" if you're not using LVM-thin

    # Check available free space before proceeding
    check_lvm_space "$VG" "$DISK_SIZE" "$LVTYPE"

    # Create the LXC container
    create_lxc_container "$CTID" "$HOSTNAME" "$MEMORY" "$CORES" "$DISK_SIZE" "$STORAGE" "$BRIDGE" "$NET_CONFIG"
}

# Run the main function
main
