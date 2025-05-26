#!/bin/bash
# deploy-ceo-investment.sh - Production CEO Investment Assistant Deployment
# Version: 2.0
# Compatible with: Proxmox VE 7.0+
# Following: https://github.com/community-scripts/ProxmoxVE best practices

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'       # Secure Internal Field Separator

# Script metadata
readonly SCRIPT_NAME="CEO Investment Assistant Deployment"
readonly SCRIPT_VERSION="2.0"
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

# Logging functions with timestamp and levels
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
        
        # Stop and remove created VMs
        for vm_id in "${CREATED_VMS[@]}"; do
            if qm status "$vm_id" >/dev/null 2>&1; then
                warning "Cleaning up VM $vm_id"
                qm stop "$vm_id" || true
                sleep 5
                qm destroy "$vm_id" || true
            fi
        done
        
        # Remove temporary files
        for temp_file in "${TEMP_FILES[@]}"; do
            rm -f "$temp_file" || true
        done
        
        error "Cleanup completed. Check logs at $LOG_FILE"
    fi
    
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Initialize logging
readonly LOG_DIR="/var/log/ceo-investment"
readonly LOG_FILE="$LOG_DIR/deployment-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"

# Configuration with auto-detection and validation
detect_configuration() {
    log "Auto-detecting Proxmox configuration..."
    
    # Detect Proxmox node
    PROXMOX_NODE=$(hostname)
    
    # Detect storage pools
    local storage_pools
    storage_pools=$(pvesm status --content images | awk 'NR>1 {print $1}' | head -1)
    STORAGE_POOL=${storage_pools:-"local-lvm"}
    
    # Detect network bridge
    local bridges
    bridges=$(ip link show | grep -o 'vmbr[0-9]*' | head -1)
    NETWORK_BRIDGE=${bridges:-"vmbr0"}
    
    # Detect gateway and network
    local gateway
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    GATEWAY=${gateway:-"192.168.1.1"}
    
    # Calculate network range from gateway
    local network_base
    network_base=$(echo "$GATEWAY" | cut -d. -f1-3)
    SUBNET_MASK="24"
    
    # Auto-assign IPs with availability check
    N8N_IP="${network_base}.50"
    DB_IP="${network_base}.51"
    DASHBOARD_IP="${network_base}.52"
    
    # Other configuration
    TEMPLATE_ID=9000
    DNS_SERVERS="8.8.8.8,1.1.1.1"
    DOMAIN="local"
    SSH_PUBLIC_KEY_PATH="/root/.ssh/id_rsa.pub"
    SSH_USER="ubuntu"
    
    # Application configuration
    CEO_EMAIL="ceo@company.local"
    COMPANY_NAME="Your Company"
    
    # Generate secure passwords
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    N8N_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    log "Configuration detected and validated"
}

# Comprehensive prerequisite validation
validate_prerequisites() {
    log "Validating prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
    
    # Check Proxmox version
    local pve_version
    if ! command -v pveversion >/dev/null 2>&1; then
        error "This script must be run on a Proxmox VE server"
        exit 1
    fi
    
    pve_version=$(pveversion | head -1 | grep -o '[0-9]\+\.[0-9]\+' | head -1)
    if ! version_ge "$pve_version" "$MIN_PROXMOX_VERSION"; then
        error "Proxmox VE $MIN_PROXMOX_VERSION or higher required. Found: $pve_version"
        exit 1
    fi
    
    # Check required commands
    local required_commands=("qm" "pvesm" "openssl" "ssh-keygen")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # Check template exists
    if ! qm list | grep -q "^$TEMPLATE_ID.*template"; then
        error "Template $TEMPLATE_ID not found. Please create Ubuntu 22.04 template first."
        show_template_creation_guide
        exit 1
    fi
    
    # Check VM IDs availability
    local vm_ids=(200 201 202)
    for vm_id in "${vm_ids[@]}"; do
        if qm list | grep -q "^$vm_id "; then
            error "VM ID $vm_id already exists. Please remove or choose different IDs."
            exit 1
        fi
    done
    
    # Check available memory
    local total_memory_gb
    total_memory_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_memory_gb" -lt "$REQUIRED_MEMORY_GB" ]; then
        error "Insufficient memory. Required: ${REQUIRED_MEMORY_GB}GB, Available: ${total_memory_gb}GB"
        exit 1
    fi
    
    # Check available storage
    local available_storage_gb
    available_storage_gb=$(pvesm status | grep "$STORAGE_POOL" | awk '{print int($4/1024/1024/1024)}')
    if [ "$available_storage_gb" -lt "$REQUIRED_STORAGE_GB" ]; then
        error "Insufficient storage. Required: ${REQUIRED_STORAGE_GB}GB, Available: ${available_storage_gb}GB"
        exit 1
    fi
    
    # Check network connectivity
    if ! curl -s --connect-timeout 10 https://packages.grafana.com >/dev/null; then
        error "No internet connectivity. Required for package downloads."
        exit 1
    fi
    
    # Check IP availability
    local ips=("$N8N_IP" "$DB_IP" "$DASHBOARD_IP")
    for ip in "${ips[@]}"; do
        if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
            error "IP address $ip is already in use"
            exit 1
        fi
    done
    
    log "All prerequisites validated successfully"
}

# Version comparison function
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Show template creation guide
show_template_creation_guide() {
    cat << 'EOF'

To create the required Ubuntu 22.04 template, run these commands:

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

EOF
}

# Enhanced VM creation with validation
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local vm_ip=$3
    local cores=$4
    local memory=$5
    local disk_size=$6
    
    log "Creating VM $vm_id: $vm_name"
    
    # Validate parameters
    if [[ ! "$vm_id" =~ ^[0-9]+$ ]] || [ "$vm_id" -lt 100 ] || [ "$vm_id" -gt 999999 ]; then
        error "Invalid VM ID: $vm_id"
        return 1
    fi
    
    if [[ ! "$vm_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid IP address: $vm_ip"
        return 1
    fi
    
    # Clone from template with error handling
    if ! qm clone "$TEMPLATE_ID" "$vm_id" --name "$vm_name" --full; then
        error "Failed to clone template $TEMPLATE_ID to VM $vm_id"
        return 1
    fi
    
    # Add to cleanup list immediately
    CREATED_VMS+=("$vm_id")
    
    # Configure VM with validation
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
        --protection 0
        --tags "ceo-investment,production,$(date +%Y-%m-%d)"
    )
    
    if ! qm set "$vm_id" "${vm_config_args[@]}"; then
        error "Failed to configure VM $vm_id"
        return 1
    fi
    
    # Resize disk with validation
    if ! qm resize "$vm_id" scsi0 "$disk_size"; then
        error "Failed to resize disk for VM $vm_id"
        return 1
    fi
    
    log "VM $vm_id ($vm_name) created successfully"
    return 0
}

# Enhanced VM startup with better waiting logic
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
        # Check if VM is running
        if qm status "$vm_id" | grep -q "status: running"; then
            # Check SSH connectivity
            if timeout 5 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$vm_ip" "echo 'VM Ready'" >/dev/null 2>&1; then
                log "VM $vm_id is ready and accessible!"
                
                # Additional verification - check if cloud-init is complete
                if ssh -o StrictHostKeyChecking=no "$SSH_USER@$vm_ip" "sudo cloud-init status --wait" >/dev/null 2>&1; then
                    log "VM $vm_id cloud-init completed"
                    return 0
                fi
            fi
        fi
        
        sleep $check_interval
        count=$((count + check_interval))
        printf "."
    done
    
    echo
    error "VM $vm_id failed to become accessible within $max_wait seconds"
    
    # Debugging information
    info "VM Status: $(qm status "$vm_id")"
    info "Network test: $(ping -c 1 "$vm_ip" 2>&1 || echo "Ping failed")"
    
    return 1
}

# Secure remote script execution with validation
execute_remote_script() {
    local vm_ip=$1
    local script_content=$2
    local script_name=${3:-"install"}
    
    # Create secure temporary script
    local temp_script
    temp_script=$(mktemp -p /tmp "ceo-install-${script_name}-XXXXXX.sh")
    TEMP_FILES+=("$temp_script")
    
    # Write script with proper headers
    cat > "$temp_script" << 'SCRIPT_HEADER'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Logging functions
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >&2; }

SCRIPT_HEADER
    
    echo "$script_content" >> "$temp_script"
    
    chmod +x "$temp_script"
    
    # Copy and execute with proper error handling
    if ! scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$temp_script" "$SSH_USER@$vm_ip:/tmp/${script_name}.sh"; then
        error "Failed to copy script to VM $vm_ip"
        return 1
    fi
    
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$SSH_USER@$vm_ip" "sudo bash /tmp/${script_name}.sh"; then
        error "Failed to execute script on VM $vm_ip"
        return 1
    fi
    
    # Cleanup remote script
    ssh -o StrictHostKeyChecking=no "$SSH_USER@$vm_ip" "sudo rm -f /tmp/${script_name}.sh" || true
    
    return 0
}

# Enhanced database installation with security hardening
get_database_install_script() {
    cat << 'EOF'
log "Starting secure database installation..."

# Update system with security patches
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Install PostgreSQL 15 and Redis with security
log "Installing PostgreSQL 15 and Redis..."
apt-get install -y postgresql-15 postgresql-contrib redis-server postgresql-client pwgen

# Secure PostgreSQL installation
log "Securing PostgreSQL installation..."
systemctl start postgresql
systemctl enable postgresql

# Generate secure passwords if not provided
DB_PASSWORD_ESCAPED=$(printf '%s\n' "$DB_PASSWORD" | sed 's/[[\.*^$()+?{|]/\\&/g')
REDIS_PASSWORD_ESCAPED=$(printf '%s\n' "$REDIS_PASSWORD" | sed 's/[[\.*^$()+?{|]/\\&/g')

# Configure PostgreSQL with security
sudo -u postgres psql << PSQL_EOF
-- Create databases
CREATE DATABASE n8n WITH ENCODING 'UTF8' LC_COLLATE='en_AU.UTF-8' LC_CTYPE='en_AU.UTF-8';
CREATE DATABASE investment_data WITH ENCODING 'UTF8' LC_COLLATE='en_AU.UTF-8' LC_CTYPE='en_AU.UTF-8';

-- Create user with limited privileges
CREATE USER n8n WITH ENCRYPTED PASSWORD '$DB_PASSWORD_ESCAPED';

-- Grant specific privileges
GRANT CONNECT ON DATABASE n8n TO n8n;
GRANT CONNECT ON DATABASE investment_data TO n8n;
ALTER DATABASE n8n OWNER TO n8n;
ALTER DATABASE investment_data OWNER TO n8n;

-- Set connection limits
ALTER USER n8n CONNECTION LIMIT 20;

\q
PSQL_EOF

# Secure PostgreSQL configuration
log "Configuring PostgreSQL security..."
PG_CONFIG="/etc/postgresql/15/main/postgresql.conf"
PG_HBA="/etc/postgresql/15/main/pg_hba.conf"

# Backup original configs
cp "$PG_CONFIG" "${PG_CONFIG}.backup"
cp "$PG_HBA" "${PG_HBA}.backup"

# Configure PostgreSQL for network access with security
cat >> "$PG_CONFIG" << PG_CONFIG_EOF

# Performance and security tuning
shared_buffers = 256MB
effective_cache_size = 1GB
work_mem = 4MB
maintenance_work_mem = 64MB
checkpoint_completion_target = 0.7
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200

# Security settings
log_statement = 'mod'
log_min_duration_statement = 1000
log_connections = on
log_disconnections = on
log_hostname = on
max_connections = 50
listen_addresses = '192.168.0.51'
ssl = on
ssl_cert_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem'
ssl_key_file = '/etc/ssl/private/ssl-cert-snakeoil.key'

PG_CONFIG_EOF

# Configure host-based authentication with security
cat >> "$PG_HBA" << PG_HBA_EOF

# CEO Investment system connections with SSL
hostssl n8n             n8n             192.168.0.50/32         md5
hostssl investment_data n8n             192.168.0.50/32         md5
hostssl n8n             n8n             192.168.0.52/32         md5
hostssl investment_data n8n             192.168.0.52/32         md5

PG_HBA_EOF

# Configure Redis with security
log "Configuring Redis security..."
REDIS_CONFIG="/etc/redis/redis.conf"
cp "$REDIS_CONFIG" "${REDIS_CONFIG}.backup"

# Update Redis configuration securely
sed -i "s/^bind 127.0.0.1/bind 192.168.0.51/" "$REDIS_CONFIG"
sed -i "s/^# requirepass foobared/requirepass $REDIS_PASSWORD_ESCAPED/" "$REDIS_CONFIG"
sed -i "s/^# maxmemory <bytes>/maxmemory 512MB/" "$REDIS_CONFIG"
sed -i "s/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/" "$REDIS_CONFIG"

# Add additional Redis security
cat >> "$REDIS_CONFIG" << REDIS_CONFIG_EOF

# Security settings
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command CONFIG "CONFIG_$REDIS_PASSWORD_ESCAPED"

REDIS_CONFIG_EOF

# Restart services
log "Restarting database services..."
systemctl restart postgresql redis-server

# Verify services are running
if ! systemctl is-active --quiet postgresql; then
    error "PostgreSQL failed to start"
    exit 1
fi

if ! systemctl is-active --quiet redis-server; then
    error "Redis failed to start"
    exit 1
fi

# Create investment database schema with proper security
log "Creating investment database schema..."
sudo -u postgres psql -d investment_data << 'SCHEMA_EOF'
-- Create extension for UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Portfolio Holdings Table with enhanced security
CREATE TABLE portfolio_holdings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    symbol VARCHAR(10) NOT NULL CHECK (symbol ~ '^[A-Z0-9.]{1,10}$'),
    company_name VARCHAR(255) NOT NULL,
    quantity DECIMAL(15, 4) NOT NULL CHECK (quantity > 0),
    average_cost DECIMAL(10, 4) NOT NULL CHECK (average_cost > 0),
    purchase_date DATE NOT NULL CHECK (purchase_date <= CURRENT_DATE),
    holding_type VARCHAR(20) DEFAULT 'long_term' CHECK (holding_type IN ('long_term', 'short_term')),
    sector VARCHAR(50),
    market_cap BIGINT CHECK (market_cap > 0),
    currency VARCHAR(3) DEFAULT 'AUD' CHECK (currency IN ('AUD', 'USD', 'EUR', 'GBP')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create index for performance
CREATE INDEX idx_portfolio_symbol ON portfolio_holdings(symbol);
CREATE INDEX idx_portfolio_date ON portfolio_holdings(purchase_date);

-- Market Data Cache with validation
CREATE TABLE market_data_cache (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    symbol VARCHAR(10) NOT NULL CHECK (symbol ~ '^[A-Z0-9.]{1,10}$'),
    price DECIMAL(10, 4) CHECK (price >= 0),
    change_percent DECIMAL(6, 4),
    volume BIGINT CHECK (volume >= 0),
    high_52w DECIMAL(10, 4) CHECK (high_52w >= 0),
    low_52w DECIMAL(10, 4) CHECK (low_52w >= 0),
    market_cap BIGINT CHECK (market_cap >= 0),
    pe_ratio DECIMAL(6, 2) CHECK (pe_ratio >= 0),
    dividend_yield DECIMAL(5, 4) CHECK (dividend_yield >= 0 AND dividend_yield <= 1),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(symbol, DATE(last_updated))
);

CREATE INDEX idx_market_data_symbol_date ON market_data_cache(symbol, last_updated);

-- Analysis History with retention policy
CREATE TABLE analysis_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    market_sentiment_score INTEGER CHECK (market_sentiment_score BETWEEN 1 AND 10),
    portfolio_risk_score INTEGER CHECK (portfolio_risk_score BETWEEN 1 AND 10),
    portfolio_value DECIMAL(12, 2) CHECK (portfolio_value >= 0),
    daily_pnl DECIMAL(10, 2),
    recommendations JSONB,
    claude_analysis TEXT,
    market_data JSONB,
    execution_time INTEGER CHECK (execution_time >= 0),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_analysis_date ON analysis_history(date);
CREATE INDEX idx_analysis_created ON analysis_history(created_at);

-- User Preferences with validation
CREATE TABLE user_preferences (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_name VARCHAR(100) DEFAULT 'CEO' CHECK (length(user_name) > 0),
    email VARCHAR(255) NOT NULL CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    risk_tolerance VARCHAR(20) DEFAULT 'moderate' CHECK (risk_tolerance IN ('conservative', 'moderate', 'aggressive')),
    target_return DECIMAL(4, 2) DEFAULT 10.00 CHECK (target_return BETWEEN 0 AND 100),
    max_position_size DECIMAL(4, 2) DEFAULT 5.00 CHECK (max_position_size BETWEEN 0 AND 100),
    notification_time TIME DEFAULT '07:00:00',
    notification_enabled BOOLEAN DEFAULT true,
    tax_rate DECIMAL(4, 2) DEFAULT 47.00 CHECK (tax_rate BETWEEN 0 AND 100),
    investment_horizon VARCHAR(20) DEFAULT 'long_term' CHECK (investment_horizon IN ('short_term', 'medium_term', 'long_term')),
    base_currency VARCHAR(3) DEFAULT 'AUD' CHECK (base_currency IN ('AUD', 'USD', 'EUR', 'GBP')),
    usd_aud_hedge_ratio DECIMAL(4, 2) DEFAULT 0.00 CHECK (usd_aud_hedge_ratio BETWEEN 0 AND 100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Exchange Rates with validation
CREATE TABLE exchange_rates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    from_currency VARCHAR(3) NOT NULL CHECK (from_currency IN ('AUD', 'USD', 'EUR', 'GBP')),
    to_currency VARCHAR(3) NOT NULL CHECK (to_currency IN ('AUD', 'USD', 'EUR', 'GBP')),
    rate DECIMAL(10, 6) NOT NULL CHECK (rate > 0),
    date DATE NOT NULL CHECK (date <= CURRENT_DATE),
    source VARCHAR(50) DEFAULT 'yahoo_finance',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(from_currency, to_currency, date)
);

CREATE INDEX idx_exchange_rates_date ON exchange_rates(date);

-- Insert CEO's actual portfolio (validated data)
INSERT INTO portfolio_holdings (symbol, company_name, quantity, average_cost, purchase_date, sector, market_cap, holding_type, currency) VALUES
('NDQ', 'BetaShares NASDAQ 100 ETF', 4027, 31.759, '2023-01-15', 'Technology ETF', 5000000000, 'long_term', 'AUD'),
('NVDA', 'NVIDIA Corporation', 380, 94.038, '2023-02-10', 'Technology', 2900000000000, 'long_term', 'USD'),
('MSFT', 'Microsoft Corporation', 26, 339.09, '2023-01-20', 'Technology', 3100000000000, 'long_term', 'USD'), 
('AMZN', 'Amazon.com Inc', 90, 143.90, '2023-03-01', 'Consumer Discretionary', 1800000000000, 'long_term', 'USD'),
('AAPL', 'Apple Inc', 55, 193.83, '2023-02-15', 'Technology', 3500000000000, 'long_term', 'USD');

-- Insert user preferences
INSERT INTO user_preferences (email, user_name) VALUES ('ceo@company.local', 'CEO');

-- Grant specific permissions to n8n user
GRANT SELECT, INSERT, UPDATE, DELETE ON portfolio_holdings TO n8n;
GRANT SELECT, INSERT, UPDATE, DELETE ON market_data_cache TO n8n;
GRANT SELECT, INSERT, UPDATE, DELETE ON analysis_history TO n8n;
GRANT SELECT, UPDATE ON user_preferences TO n8n;
GRANT SELECT, INSERT, UPDATE ON exchange_rates TO n8n;

-- Grant sequence permissions
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO n8n;

\q
SCHEMA_EOF

# Create secure backup script
log "Creating secure backup script..."
cat > /usr/local/bin/backup-investment-db.sh << 'BACKUP_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/var/backups/investment-db"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

# Create backup directory with proper permissions
mkdir -p "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

# Backup databases with compression
sudo -u postgres pg_dump -Fc n8n > "$BACKUP_DIR/n8n_$DATE.dump"
sudo -u postgres pg_dump -Fc investment_data > "$BACKUP_DIR/investment_data_$DATE.dump"

# Set proper permissions
chmod 640 "$BACKUP_DIR"/*.dump

# Remove old backups
find "$BACKUP_DIR" -name "*.dump" -type f -mtime +$RETENTION_DAYS -delete

# Log completion
logger "Investment database backup completed: $DATE"

BACKUP_SCRIPT_EOF

chmod +x /usr/local/bin/backup-investment-db.sh

# Set up logrotate for PostgreSQL
cat > /etc/logrot
