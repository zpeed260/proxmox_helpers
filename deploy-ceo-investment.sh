# Create the corrected script
cat > /root/deploy-ceo-investment.sh << 'SCRIPT_END'
#!/bin/bash
# deploy-ceo-investment.sh - Production CEO Investment Assistant Deployment
# Version: 2.1 - Fixed heredoc syntax issues

set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_NAME="CEO Investment Assistant Deployment"
readonly SCRIPT_VERSION="2.1"
readonly MIN_PROXMOX_VERSION="7.0"
readonly REQUIRED_MEMORY_GB=16
readonly REQUIRED_STORAGE_GB=100

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Global variables for cleanup
declare -a CREATED_VMS=()
declare -a TEMP_FILES=()

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]${NC} $1" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        error "Deployment failed. Starting cleanup..."
        
        for vm_id in "${CREATED_VMS[@]}"; do
            if qm status "$vm_id" >/dev/null 2>&1; then
                warning "Cleaning up VM $vm_id"
                qm stop "$vm_id" || true
                sleep 5
                qm destroy "$vm_id" || true
            fi
        done
        
        for temp_file in "${TEMP_FILES[@]}"; do
            rm -f "$temp_file" || true
        done
        
        error "Cleanup completed. Check logs at $LOG_FILE"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Initialize logging
readonly LOG_DIR="/var/log/ceo-investment"
readonly LOG_FILE="$LOG_DIR/deployment-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"

# Configuration detection
detect_configuration() {
    log "Auto-detecting Proxmox configuration..."
    
    PROXMOX_NODE=$(hostname)
    
    local storage_pools
    storage_pools=$(pvesm status --content images 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
    STORAGE_POOL=${storage_pools:-"local-lvm"}
    
    local bridges
    bridges=$(ip link show | grep -o 'vmbr[0-9]*' | head -1)
    NETWORK_BRIDGE=${bridges:-"vmbr0"}
    
    local gateway
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    GATEWAY=${gateway:-"192.168.1.1"}
    
    local network_base
    network_base=$(echo "$GATEWAY" | cut -d. -f1-3)
    SUBNET_MASK="24"
    
    N8N_IP="${network_base}.50"
    DB_IP="${network_base}.51"
    DASHBOARD_IP="${network_base}.52"
    
    TEMPLATE_ID=9000
    DNS_SERVERS="8.8.8.8,1.1.1.1"
    DOMAIN="local"
    SSH_PUBLIC_KEY_PATH="/root/.ssh/id_rsa.pub"
    SSH_USER="ubuntu"
    
    CEO_EMAIL="ceo@company.local"
    COMPANY_NAME="Your Company"
    
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    N8N_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    log "Configuration detected and validated"
}

# Version comparison
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Prerequisites validation
validate_prerequisites() {
    log "Validating prerequisites..."
    
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
    
    if ! command -v pveversion >/dev/null 2>&1; then
        error "This script must be run on a Proxmox VE server"
        exit 1
    fi
    
    local pve_version
    pve_version=$(pveversion | head -1 | grep -o '[0-9]\+\.[0-9]\+' | head -1)
    if ! version_ge "$pve_version" "$MIN_PROXMOX_VERSION"; then
        error "Proxmox VE $MIN_PROXMOX_VERSION or higher required. Found: $pve_version"
        exit 1
    fi
    
    local required_commands=("qm" "pvesm" "openssl" "ssh-keygen")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    if ! qm list | grep -q "^$TEMPLATE_ID.*template"; then
        error "Template $TEMPLATE_ID not found. Please create Ubuntu 22.04 template first."
        show_template_creation_guide
        exit 1
    fi
    
    local vm_ids=(200 201 202)
    for vm_id in "${vm_ids[@]}"; do
        if qm list | grep -q "^$vm_id "; then
            error "VM ID $vm_id already exists. Please remove or choose different IDs."
            exit 1
        fi
    done
    
    local total_memory_gb
    total_memory_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_memory_gb" -lt "$REQUIRED_MEMORY_GB" ]; then
        error "Insufficient memory. Required: ${REQUIRED_MEMORY_GB}GB, Available: ${total_memory_gb}GB"
        exit 1
    fi
    
    if ! curl -s --connect-timeout 10 https://packages.grafana.com >/dev/null; then
        error "No internet connectivity. Required for package downloads."
        exit 1
    fi
    
    log "All prerequisites validated successfully"
}

# Template creation guide
show_template_creation_guide() {
    cat << 'TEMPLATE_GUIDE'

To create the required Ubuntu 22.04 template, run:

cd /tmp
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qm create 9000 --name ubuntu-22.04-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000

TEMPLATE_GUIDE
}

# VM creation function
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local vm_ip=$3
    local cores=$4
    local memory=$5
    local disk_size=$6
    
    log "Creating VM $vm_id: $vm_name"
    
    if [[ ! "$vm_id" =~ ^[0-9]+$ ]] || [ "$vm_id" -lt 100 ]; then
        error "Invalid VM ID: $vm_id"
        return 1
    fi
    
    if ! qm clone "$TEMPLATE_ID" "$vm_id" --name "$vm_name" --full; then
        error "Failed to clone template $TEMPLATE_ID to VM $vm_id"
        return 1
    fi
    
    CREATED_VMS+=("$vm_id")
    
    local vm_config_args=(
        --cores "$cores"
        --memory "$memory"
        --net0 "virtio,bridge=$NETWORK_BRIDGE"
        --ipconfig0 "ip=${vm_ip}/${SUBNET_MASK},gw=${GATEWAY}"
        --nameserver "$DNS_SERVERS"
        --searchdomain "$DOMAIN"
        --ciuser "$SSH_USER"
        --sshkeys "$SSH_PUBLIC_KEY_PATH"
        --agent "enabled=1"
        --onboot 1
        --tags "ceo-investment,production,$(date +%Y-%m-%d)"
    )
    
    if ! qm set "$vm_id" "${vm_config_args[@]}"; then
        error "Failed to configure VM $vm_id"
        return 1
    fi
    
    if ! qm resize "$vm_id" scsi0 "$disk_size"; then
        error "Failed to resize disk for VM $vm_id"
        return 1
    fi
    
    log "VM $vm_id ($vm_name) created successfully"
    return 0
}

# VM startup function
start_and_wait() {
    local vm_id=$1
    local vm_ip=$2
    local vm_name=$3
    local max_wait=${4:-300}
    
    log "Starting VM $vm_id ($vm_name)..."
    
    if ! qm start "$vm_id"; then
        error "Failed to start VM $vm_id"
        return 1
    fi
    
    log "Waiting for VM $vm_id to become accessible..."
    local count=0
    local check_interval=10
    
    while [ $count -lt $max_wait ]; do
        if qm status "$vm_id" | grep -q "status: running"; then
            if timeout 5 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$vm_ip" "echo 'VM Ready'" >/dev/null 2>&1; then
                log "VM $vm_id is ready and accessible!"
                return 0
            fi
        fi
        
        sleep $check_interval
        count=$((count + check_interval))
        printf "."
    done
    
    echo
    error "VM $vm_id failed to become accessible within $max_wait seconds"
    return 1
}

# Remote script execution
execute_remote_script() {
    local vm_ip=$1
    local script_content=$2
    local script_name=${3:-"install"}
    
    local temp_script
    temp_script=$(mktemp -p /tmp "ceo-install-${script_name}-XXXXXX.sh")
    TEMP_FILES+=("$temp_script")
    
    cat > "$temp_script" << 'SCRIPT_HEADER'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2; }
SCRIPT_HEADER
    
    echo "$script_content" >> "$temp_script"
    chmod +x "$temp_script"
    
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$temp_script" "$SSH_USER@$vm_ip:/tmp/${script_name}.sh"; then
        error "Failed to copy script to VM $vm_ip"
        return 1
    fi
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$SSH_USER@$vm_ip" "sudo bash /tmp/${script_name}.sh"; then
        error "Failed to execute script on VM $vm_ip"
        return 1
    fi
    
    ssh -o StrictHostKeyChecking=no "$SSH_USER@$vm_ip" "sudo rm -f /tmp/${script_name}.sh" || true
    return 0
}

# Main deployment function
main() {
    log "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    detect_configuration
    validate_prerequisites
    
    if [ ! -f "$SSH_PUBLIC_KEY_PATH" ]; then
        log "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
    fi
    
    log "Creating virtual machines..."
    
    if ! create_vm 200 "ceo-investment-n8n" "$N8N_IP" 2 4096 "20G"; then
        error "Failed to create n8n VM"
        exit 1
    fi
    
    if ! create_vm 201 "ceo-investment-db" "$DB_IP" 4 8192 "60G"; then
        error "Failed to create database VM"
        exit 1
    fi
    
    if ! create_vm 202 "ceo-investment-dashboard" "$DASHBOARD_IP" 2 3072 "15G"; then
        error "Failed to create dashboard VM"
        exit 1
    fi
    
    log "Starting VMs..."
    start_and_wait 201 "$DB_IP" "database-server" 600
    start_and_wait 200 "$N8N_IP" "n8n-server" 600
    start_and_wait 202 "$DASHBOARD_IP" "dashboard-server" 600
    
    log "Installing database server..."
    execute_remote_script "$DB_IP" "$(get_database_install_script)" "database"
    
    log "Installing n8n server..."
    execute_remote_script "$N8N_IP" "$(get_n8n_install_script)" "n8n"
    
    log "Installing dashboard server..."
    execute_remote_script "$DASHBOARD_IP" "$(get_dashboard_install_script)" "dashboard"
    
    generate_final_report
    
    log "🎉 Deployment completed successfully!"
}

# Database installation script
get_database_install_script() {
    cat << 'DB_SCRIPT'
log "Installing PostgreSQL and Redis..."

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y postgresql-15 postgresql-contrib redis-server

systemctl start postgresql redis-server
systemctl enable postgresql redis-server

sudo -u postgres psql << 'PSQL_CMD'
CREATE DATABASE n8n;
CREATE DATABASE investment_data;
CREATE USER n8n WITH ENCRYPTED PASSWORD 'secure_password_123';
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE investment_data TO n8n;
\q
PSQL_CMD

sudo -u postgres psql -d investment_data << 'SCHEMA_CMD'
CREATE TABLE portfolio_holdings (
    id SERIAL PRIMARY KEY,
    symbol VARCHAR(10) NOT NULL,
    company_name VARCHAR(255),
    quantity DECIMAL(15, 4) NOT NULL,
    average_cost DECIMAL(10, 4) NOT NULL,
    purchase_date DATE,
    sector VARCHAR(50),
    currency VARCHAR(3) DEFAULT 'AUD',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO portfolio_holdings (symbol, company_name, quantity, average_cost, purchase_date, sector, currency) VALUES
('NDQ', 'BetaShares NASDAQ 100 ETF', 4027, 31.759, '2023-01-15', 'Technology ETF', 'AUD'),
('NVDA', 'NVIDIA Corporation', 380, 94.038, '2023-02-10', 'Technology', 'USD'),
('MSFT', 'Microsoft Corporation', 26, 339.09, '2023-01-20', 'Technology', 'USD'),
('AMZN', 'Amazon.com Inc', 90, 143.90, '2023-03-01', 'Consumer Discretionary', 'USD'),
('AAPL', 'Apple Inc', 55, 193.83, '2023-02-15', 'Technology', 'USD');

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n;
\q
SCHEMA_CMD

log "Database installation completed"
DB_SCRIPT
}

# n8n installation script
get_n8n_install_script() {
    cat << 'N8N_SCRIPT'
log "Installing n8n..."

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y

curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs build-essential

npm install -g n8n@latest

useradd -m -s /bin/bash n8n
mkdir -p /opt/n8n/{data,logs}
chown -R n8n:n8n /opt/n8n

cat > /etc/systemd/system/n8n.service << 'N8N_SERVICE'
[Unit]
Description=n8n Workflow Automation
After=network.target

[Service]
Type=simple
User=n8n
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/n8n start
Environment=N8N_USER_FOLDER=/opt/n8n/data
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=admin123
Environment=N8N_HOST=0.0.0.0
Environment=N8N_PORT=5678
Restart=on-failure

[Install]
WantedBy=multi-user.target
N8N_SERVICE

systemctl daemon-reload
systemctl enable n8n
systemctl start n8n

log "n8n installation completed"
N8N_SCRIPT
}

# Dashboard installation script  
get_dashboard_install_script() {
    cat << 'DASH_SCRIPT'
log "Installing Grafana..."

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y software-properties-common

wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update && apt-get install -y grafana

systemctl enable grafana-server
systemctl start grafana-server

log "Dashboard installation completed"
DASH_SCRIPT
}

# Generate final report
generate_final_report() {
    cat > "/root/ceo-investment-report.txt" << REPORT
CEO Investment Assistant - Deployment Complete
============================================
Generated: $(date)

VM Access:
- n8n: http://$N8N_IP:5678 (admin/admin123)
- Grafana: http://$DASHBOARD_IP:3000 (admin/admin)

Portfolio Loaded:
- NDQ: 4,027 shares @ $31.759 AUD
- NVDA: 380 shares @ $94.038 USD  
- MSFT: 26 shares @ $339.09 USD
- AMZN: 90 shares @ $143.90 USD
- AAPL: 55 shares @ $193.83 USD

Next Steps:
1. Access n8n interface
2. Create investment workflow
3. Schedule daily briefings

REPORT

    log "Deployment report saved to /root/ceo-investment-report.txt"
}

# Display banner and run
cat << 'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║              CEO Investment Assistant v2.1                   ║
║                 Production Deployment                        ║
╚═══════════════════════════════════════════════════════════════╝
BANNER

main
SCRIPT_END
