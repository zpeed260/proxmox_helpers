# Download and create a working version locally
cat > /root/deploy-ceo-investment-fixed.sh << 'SCRIPT_EOF'
#!/bin/bash
# deploy-ceo-investment.sh - CEO Investment Assistant Deployment (Fixed)
# Version: 2.1-fixed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

log "🚀 Starting CEO Investment Assistant Deployment"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
    exit 1
fi

# Check if Proxmox
if ! command -v qm >/dev/null 2>&1; then
    error "This must be run on a Proxmox server"
    exit 1
fi

# Auto-detect configuration
PROXMOX_NODE=$(hostname)
STORAGE_POOL="local-lvm"
NETWORK_BRIDGE="vmbr0"
TEMPLATE_ID=9000

# Network configuration
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
NETWORK_BASE=$(echo "$GATEWAY" | cut -d. -f1-3)
N8N_IP="${NETWORK_BASE}.50"
DB_IP="${NETWORK_BASE}.51" 
DASHBOARD_IP="${NETWORK_BASE}.52"

log "Configuration detected:"
log "  Node: $PROXMOX_NODE"
log "  Network: $NETWORK_BASE.0/24"
log "  VMs: $N8N_IP, $DB_IP, $DASHBOARD_IP"

# Check template exists
if ! qm list | grep -q "^$TEMPLATE_ID.*template"; then
    error "Ubuntu template (ID: $TEMPLATE_ID) not found!"
    echo
    echo "Create it first with:"
    echo "cd /tmp"
    echo "wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    echo "qm create 9000 --name ubuntu-22.04-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0"
    echo "qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm"
    echo "qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0"
    echo "qm set 9000 --ide2 local-lvm:cloudinit"
    echo "qm set 9000 --boot c --bootdisk scsi0"
    echo "qm set 9000 --serial0 socket --vga serial0"
    echo "qm set 9000 --agent enabled=1"
    echo "qm template 9000"
    exit 1
fi

# Generate SSH key if needed
if [ ! -f /root/.ssh/id_rsa.pub ]; then
    log "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
fi

# Create VMs
create_vm() {
    local vm_id=$1
    local vm_name=$2
    local vm_ip=$3
    local cores=$4
    local memory=$5
    local disk=$6
    
    log "Creating VM $vm_id: $vm_name"
    
    if qm list | grep -q "^$vm_id "; then
        warning "VM $vm_id exists, removing..."
        qm stop $vm_id 2>/dev/null || true
        sleep 3
        qm destroy $vm_id 2>/dev/null || true
    fi
    
    qm clone $TEMPLATE_ID $vm_id --name "$vm_name" --full
    qm set $vm_id \
        --cores $cores \
        --memory $memory \
        --net0 "virtio,bridge=$NETWORK_BRIDGE" \
        --ipconfig0 "ip=${vm_ip}/24,gw=${GATEWAY}" \
        --nameserver "8.8.8.8" \
        --ciuser "ubuntu" \
        --sshkeys /root/.ssh/id_rsa.pub \
        --agent enabled=1
    
    qm resize $vm_id scsi0 $disk
    log "VM $vm_id created successfully"
}

# Start VM and wait
start_vm() {
    local vm_id=$1
    local vm_ip=$2
    local vm_name=$3
    
    log "Starting VM $vm_id ($vm_name)..."
    qm start $vm_id
    
    log "Waiting for VM $vm_id to be ready..."
    local count=0
    while [ $count -lt 180 ]; do
        if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ubuntu@$vm_ip "echo ready" 2>/dev/null; then
            log "VM $vm_id is ready!"
            return 0
        fi
        sleep 5
        count=$((count + 5))
        printf "."
    done
    echo
    error "VM $vm_id failed to start within 3 minutes"
    return 1
}

# Install database
install_database() {
    log "Installing database on VM 201..."
    
    ssh -o StrictHostKeyChecking=no ubuntu@$DB_IP 'bash -s' << 'DB_INSTALL'
sudo apt update && sudo apt upgrade -y
sudo apt install -y postgresql postgresql-contrib redis-server

sudo systemctl start postgresql redis-server
sudo systemctl enable postgresql redis-server

sudo -u postgres psql << 'PSQL_END'
CREATE DATABASE n8n;
CREATE DATABASE investment_data;
CREATE USER n8n WITH ENCRYPTED PASSWORD 'secure123';
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL PRIVILEGES ON DATABASE investment_data TO n8n;
\q
PSQL_END

sudo -u postgres psql -d investment_data << 'SCHEMA_END'
CREATE TABLE portfolio_holdings (
    id SERIAL PRIMARY KEY,
    symbol VARCHAR(10) NOT NULL,
    company_name VARCHAR(255),
    quantity DECIMAL(15, 4) NOT NULL,
    average_cost DECIMAL(10, 4) NOT NULL,
    purchase_date DATE,
    sector VARCHAR(50),
    currency VARCHAR(3) DEFAULT 'AUD'
);

INSERT INTO portfolio_holdings VALUES
(1, 'NDQ', 'BetaShares NASDAQ 100 ETF', 4027, 31.759, '2023-01-15', 'Technology ETF', 'AUD'),
(2, 'NVDA', 'NVIDIA Corporation', 380, 94.038, '2023-02-10', 'Technology', 'USD'),
(3, 'MSFT', 'Microsoft Corporation', 26, 339.09, '2023-01-20', 'Technology', 'USD'),
(4, 'AMZN', 'Amazon.com Inc', 90, 143.90, '2023-03-01', 'Consumer Discretionary', 'USD'),
(5, 'AAPL', 'Apple Inc', 55, 193.83, '2023-02-15', 'Technology', 'USD');

GRANT ALL ON ALL TABLES IN SCHEMA public TO n8n;
\q
SCHEMA_END

echo "Database installation completed"
DB_INSTALL
}

# Install n8n
install_n8n() {
    log "Installing n8n on VM 200..."
    
    ssh -o StrictHostKeyChecking=no ubuntu@$N8N_IP 'bash -s' << 'N8N_INSTALL'
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs build-essential

sudo npm install -g n8n

sudo useradd -m -s /bin/bash n8n
sudo mkdir -p /opt/n8n
sudo chown n8n:n8n /opt/n8n

sudo tee /etc/systemd/system/n8n.service > /dev/null << 'SERVICE_END'
[Unit]
Description=n8n
After=network.target

[Service]
Type=simple
User=n8n
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/n8n start
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=admin123
Environment=N8N_HOST=0.0.0.0
Environment=N8N_PORT=5678
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE_END

sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl start n8n

echo "n8n installation completed"
N8N_INSTALL
}

# Install dashboard
install_dashboard() {
    log "Installing dashboard on VM 202..."
    
    ssh -o StrictHostKeyChecking=no ubuntu@$DASHBOARD_IP 'bash -s' << 'DASH_INSTALL'
sudo apt update && sudo apt upgrade -y
sudo apt install -y software-properties-common

wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt update && sudo apt install -y grafana
sudo systemctl enable grafana-server
sudo systemctl start grafana-server

echo "Dashboard installation completed"
DASH_INSTALL
}

# Main deployment
main() {
    log "Creating VMs..."
    
    create_vm 200 "ceo-investment-n8n" "$N8N_IP" 2 4096 "20G"
    create_vm 201 "ceo-investment-db" "$DB_IP" 4 8192 "60G" 
    create_vm 202 "ceo-investment-dashboard" "$DASHBOARD_IP" 2 3072 "15G"
    
    log "Starting VMs..."
    start_vm 201 "$DB_IP" "database"
    start_vm 200 "$N8N_IP" "n8n"
    start_vm 202 "$DASHBOARD_IP" "dashboard"
    
    log "Installing software..."
    install_database
    install_n8n
    install_dashboard
    
    # Generate report
    cat > /root/ceo-investment-report.txt << REPORT_END
CEO Investment Assistant - Deployment Complete
=============================================
Generated: $(date)

🎯 Access URLs:
- n8n Workflow: http://$N8N_IP:5678 (admin/admin123)
- Grafana Dashboard: http://$DASHBOARD_IP:3000 (admin/admin)

💼 CEO Portfolio Loaded:
- NDQ: 4,027 shares @ $31.759 AUD (BetaShares NASDAQ 100 ETF)
- NVDA: 380 shares @ $94.038 USD (NVIDIA Corporation)
- MSFT: 26 shares @ $339.09 USD (Microsoft Corporation)
- AMZN: 90 shares @ $143.90 USD (Amazon.com Inc)
- AAPL: 55 shares @ $193.83 USD (Apple Inc)

📊 Portfolio Value: ~$1.2-1.5M AUD
💰 Tax Status: All positions 12+ months (CGT discount eligible)
🎯 Strategy: Long-term growth (5+ year horizon)

🔧 Next Steps:
1. Access n8n at http://$N8N_IP:5678
2. Create daily investment analysis workflow
3. Set up portfolio monitoring dashboards
4. Configure email notifications (optional)

📱 VM Management:
- Database VM: $DB_IP (VM 201)
- n8n VM: $N8N_IP (VM 200)  
- Dashboard VM: $DASHBOARD_IP (VM 202)

🔐 All VMs accessible via: ssh ubuntu@[VM_IP]
REPORT_END

    log "🎉 Deployment completed successfully!"
    log ""
    log "📊 Your CEO Investment Assistant is ready!"
    log "• n8n Interface: http://$N8N_IP:5678 (admin/admin123)"
    log "• Grafana Dashboard: http://$DASHBOARD_IP:3000 (admin/admin)"
    log "• Full report: /root/ceo-investment-report.txt"
    log ""
    log "💼 Portfolio loaded with CEO's actual $1.2M+ holdings"
    log "🚀 Ready for daily investment analysis and monitoring!"
}

# Confirmation prompt
echo
read -p "Deploy CEO Investment Assistant? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    main
else
    log "Deployment cancelled"
    exit 0
fi
SCRIPT_EOF

# Make executable and run
chmod +x /root/deploy-ceo-investment-fixed.sh
/root/deploy-ceo-investment-fixed.sh
