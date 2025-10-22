#!/bin/bash

# Azure Single Agent Deployment Script
# Deploys a single NANDA agent on Azure VM

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
AGENT_ID="$1" # Removed stray 'd'
ANTHROPIC_API_KEY="$2"
AGENT_NAME="$3"
GIT_BRANCH="${4:-main}"
SPECIALIZATION="${5:-general assistant}"
CAPABILITIES="${6:-general,conversation,help}"
SMITHERY_API_KEY="${7:-}"
AGENT_REGISTRY_URL="${8:-http://registry.chat39.com:6900}"
MCP_REGISTRY_URL="${9:-}"
PORT="${10:-6050}"
LOCATION="${11:-eastus}"
VM_SIZE="${12:-Standard_B2s}"

# Validation
if [ -z "$AGENT_ID" ] || [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_NAME" ]; then
    echo -e "${RED}❌ Usage: $0 <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> [GIT_BRANCH] [SPECIALIZATION] [CAPABILITIES] [SMITHERY_API_KEY] [AGENT_REGISTRY_URL] [MCP_REGISTRY_URL] [PORT] [LOCATION] [VM_SIZE]${NC}"
    echo ""
    echo "Example:"
    echo "  $0 my-agent sk-ant-xxx 'My Agent' main 'coding expert' 'python,debugging' smithery-key http://registry.url http://mcp.url 6050 eastus Standard_B2s"
    exit 1
fi

# Port validation function
validate_port() {
    local port=$1
    # Allowed port ranges: 6000-6100, 7000-7100, 8000-8100, 9000-9100, 10000-10100, 11000-11100, 12000-12100, 13000-13100, 14000-14100, 15000-15100
    if (( (port >= 6000 && port <= 6100) || \
          (port >= 7000 && port <= 7100) || \
          (port >= 8000 && port <= 8100) || \
          (port >= 9000 && port <= 9100) || \
          (port >= 10000 && port <= 10100) || \
          (port >= 11000 && port <= 11100) || \
          (port >= 12000 && port <= 12100) || \
          (port >= 13000 && port <= 13100) || \
          (port >= 14000 && port <= 14100) || \
          (port >= 15000 && port <= 15100) )); then
        return 0
    else
        return 1
    fi
}

# Validate port
if ! validate_port "$PORT"; then
    echo -e "${RED}❌ Invalid port: $PORT${NC}"
    echo "Allowed port ranges: 6000-6100, 7000-7100, 8000-8100, 9000-9100, 10000-10100,"
    echo "                     11000-11100, 12000-12100, 13000-13100, 14000-14100, 15000-15100"
    exit 1
fi

# Configuration
RESOURCE_GROUP="nanda-agents-rg"
NSG_NAME="nanda-agents-nsg"
VNET_NAME="nanda-agents-vnet"
SUBNET_NAME="nanda-agents-subnet"
VM_NAME="nanda-agent-${AGENT_ID}"
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)

echo -e "${GREEN}🚀 Starting Azure Single Agent Deployment${NC}"
echo "Agent ID: $AGENT_ID"
echo "Agent Name: $AGENT_NAME"
echo "Port: $PORT"
echo "Location: $LOCATION"
echo "VM Size: $VM_SIZE"
echo ""

# [1/7] Check Azure CLI
echo -e "${YELLOW}[1/7] Checking Azure CLI...${NC}"
if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI not installed. Install from: https://docs.microsoft.com/cli/azure/install-azure-cli${NC}"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo -e "${RED}❌ Not logged in to Azure. Run 'az login' first.${NC}"
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo -e "${GREEN}✅ Using Azure subscription: $SUBSCRIPTION_ID${NC}"

# [2/7] Create or verify resource group
echo -e "${YELLOW}[2/7] Setting up resource group...${NC}"
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "Creating resource group..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi
echo -e "${GREEN}✅ Resource group: $RESOURCE_GROUP${NC}"

# [3/7] Create or verify network security group
echo -e "${YELLOW}[3/7] Setting up network security group...${NC}"
if ! az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" &> /dev/null; then
    echo "Creating network security group..."
    az network nsg create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$NSG_NAME" \
        --location "$LOCATION" \
        --output none
    
    # Add SSH rule
    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowSSH" \
        --priority 1000 \
        --source-address-prefixes '*' \
        --destination-port-ranges 22 \
        --access Allow \
        --protocol Tcp \
        --output none
    
    # Add agent port ranges
    PRIORITY=1100
    for PORT_RANGE in "6000-6100" "7000-7100" "8000-8100" "9000-9100" "10000-10100" "11000-11100" "12000-12100" "13000-13100" "14000-14100" "15000-15100"; do
        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "AllowAgentPorts${PORT_RANGE}" \
            --priority $PRIORITY \
            --source-address-prefixes '*' \
            --destination-port-ranges "$PORT_RANGE" \
            --access Allow \
            --protocol Tcp \
            --output none
        PRIORITY=$((PRIORITY + 10))
    done
    
    # Add specific rule for the agent's port (in case it's not in the ranges)
    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowAgentPort${PORT}" \
        --priority $PRIORITY \
        --source-address-prefixes '*' \
        --destination-port-ranges "$PORT" \
        --access Allow \
        --protocol Tcp \
        --output none 2>/dev/null || echo "Port $PORT rule already exists or in range"
fi
echo -e "${GREEN}✅ Network security group: $NSG_NAME${NC}"

# [4/7] Create or verify virtual network
echo -e "${YELLOW}[4/7] Setting up virtual network...${NC}"
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &> /dev/null; then
    echo "Creating virtual network..."
    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --address-prefix 10.0.0.0/16 \
        --subnet-name "$SUBNET_NAME" \
        --subnet-prefix 10.0.1.0/24 \
        --location "$LOCATION" \
        --output none
    
    # Associate NSG with subnet
    az network vnet subnet update \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$SUBNET_NAME" \
        --network-security-group "$NSG_NAME" \
        --output none
fi
echo -e "${GREEN}✅ Virtual network: $VNET_NAME${NC}"

# [5/7] Create cloud-init configuration
echo -e "${YELLOW}[5/7] Creating cloud-init configuration...${NC}"
cat > "cloud-init-${DEPLOYMENT_ID}.yaml" << EOF
#cloud-config

package_update: true
package_upgrade: true

packages:
  - python3
  - python3-venv
  - python3-pip
  - python3-dev
  - build-essential
  - git
  - curl
  - jq

runcmd:
  - |
    # Log all output
    exec > /var/log/cloud-init-output.log 2>&1
    
    echo "=== NANDA Agent Setup Started: ${DEPLOYMENT_ID} ==="
    date
    
    # Setup project as the non-root service user (azureuser) - simplified approach
    cd /home/azureuser
    sudo -u azureuser git clone https://github.com/projnanda/NEST.git nanda-agent-${AGENT_ID}
    cd nanda-agent-${AGENT_ID}
    
    # Fetch all remote branches and ensure we're on the correct branch
    echo "Fetching all remote branches..."
    sudo -u azureuser git fetch --all
    
    # Checkout the specified branch
    echo "Checking out branch: ${GIT_BRANCH}"
    sudo -u azureuser git checkout ${GIT_BRANCH}
    sudo -u azureuser git pull origin ${GIT_BRANCH}
    echo "Successfully on ${GIT_BRANCH} branch with latest changes"
    
    # Create virtual environment and install (simplified)
    sudo -u azureuser python3 -m venv env
    sudo -u azureuser bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"
    
    # Get public IP using multiple methods
    echo "Getting public IP address..."
    PUBLIC_IP=""
    
    # Try Azure metadata service first
    PUBLIC_IP=\$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null)
    
    # If that fails, try external service
    if [ -z "\$PUBLIC_IP" ]; then
        echo "Azure metadata failed, trying external service..."
        PUBLIC_IP=\$(curl -s --max-time 10 "https://api.ipify.org" 2>/dev/null)
    fi
    
    # If still no IP, try another service
    if [ -z "\$PUBLIC_IP" ]; then
        echo "External service failed, trying alternative..."
        PUBLIC_IP=\$(curl -s --max-time 10 "https://ifconfig.me/ip" 2>/dev/null)
    fi
    
    if [ -z "\$PUBLIC_IP" ]; then
        echo "WARNING: Could not retrieve public IP, using placeholder"
        PUBLIC_IP="0.0.0.0"
    else
        echo "Retrieved public IP: \$PUBLIC_IP"
    fi
    
    # Generate agent ID with hex suffix
    HEX_SUFFIX=\$(openssl rand -hex 3)
    FULL_AGENT_ID="${AGENT_ID}-\${HEX_SUFFIX}"
    
    echo "Generated agent_id: \$FULL_AGENT_ID"
    
    # Start the agent directly (simpler approach like AWS/GCP)
    echo "Starting NANDA agent with PUBLIC_URL: http://\${PUBLIC_IP}:${PORT}"
    sudo -u azureuser bash -c "
        cd /home/azureuser/nanda-agent-${AGENT_ID}
        source env/bin/activate
        export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'
        export AGENT_ID='\${FULL_AGENT_ID}'
        export AGENT_NAME='${AGENT_NAME}'
        export AGENT_DOMAIN='${AGENT_NAME}'
        export AGENT_SPECIALIZATION='${SPECIALIZATION}'
        export AGENT_DESCRIPTION='I am ${AGENT_NAME}, specializing in ${SPECIALIZATION}'
        export AGENT_CAPABILITIES='${CAPABILITIES}'
        export SMITHERY_API_KEY='${SMITHERY_API_KEY}'
        export REGISTRY_URL='${AGENT_REGISTRY_URL}'
        export MCP_REGISTRY_URL='${MCP_REGISTRY_URL}'
        export PUBLIC_URL='http://\${PUBLIC_IP}:${PORT}'
        export PORT='${PORT}'
        nohup python3 examples/nanda_agent.py > agent.log 2>&1 &
    "
    
    echo "=== NANDA Agent Setup Complete: ${DEPLOYMENT_ID} ==="
    echo "Agent is running at: http://\${PUBLIC_IP}:${PORT}/a2a"
    date
EOF

echo -e "${GREEN}✅ Cloud-init configuration created${NC}"

# [6/7] Create VM
echo -e "${YELLOW}[6/7] Creating Azure VM...${NC}"
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --size "$VM_SIZE" \
    --image Ubuntu2204 \
    --admin-username azureuser \
    --generate-ssh-keys \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --nsg "$NSG_NAME" \
    --public-ip-sku Standard \
    --custom-data "cloud-init-${DEPLOYMENT_ID}.yaml" \
    --tags "Project=NANDA" "AgentId=$AGENT_ID" "DeploymentId=$DEPLOYMENT_ID" \
    --output none

echo -e "${GREEN}✅ VM created: $VM_NAME${NC}"

# [7/7] Get VM details
echo -e "${YELLOW}[7/7] Retrieving VM details...${NC}"
PUBLIC_IP=$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query publicIps -o tsv)

echo "Waiting for agent to start (60 seconds)..."
sleep 60

# Cleanup
rm "cloud-init-${DEPLOYMENT_ID}.yaml"

# Summary
echo ""
echo -e "${GREEN}🎉 Azure Single Agent Deployment Complete!${NC}"
echo "============================================="
echo "Deployment ID: $DEPLOYMENT_ID"
echo "VM Name: $VM_NAME"
echo "Public IP: $PUBLIC_IP"
echo "Agent URL: http://$PUBLIC_IP:$PORT/a2a"
echo ""
echo "📊 Check agent status:"
echo "  ssh azureuser@$PUBLIC_IP 'ps aux | grep nanda_agent'"
echo ""
echo "📋 View agent logs:"
echo "  ssh azureuser@$PUBLIC_IP 'tail -f /home/azureuser/nanda-agent-$AGENT_ID/agent.log'"
echo ""
echo "🔄 Restart agent:"
echo "  ssh azureuser@$PUBLIC_IP 'pkill -f nanda_agent && cd /home/azureuser/nanda-agent-$AGENT_ID && source env/bin/activate && nohup python3 examples/nanda_agent.py > agent.log 2>&1 &'"
echo ""
echo "🧪 Test agent:"
echo "  curl -X POST http://$PUBLIC_IP:$PORT/a2a -H \"Content-Type: application/json\" -d '{\"content\":{\"text\":\"Hello!\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test\"}'"
echo ""
echo "🛑 To delete VM:"
echo "  az vm delete --resource-group $RESOURCE_GROUP --name $VM_NAME --yes"
echo ""
echo "🗑️  To delete entire resource group:"
echo "  az group delete --name $RESOURCE_GROUP --yes"
