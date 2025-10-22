#!/bin/bash

# Azure Multi-Agent Deployment Script
# Deploys multiple NANDA agents on a single Azure VM managed by supervisor

set -e

# Trap to clean up cloud-init file on error or exit
cleanup() {
    if [ -n "$DEPLOYMENT_ID" ] && [ -f "cloud-init-${DEPLOYMENT_ID}.yaml" ]; then
        rm -f "cloud-init-${DEPLOYMENT_ID}.yaml"
    fi
}
trap cleanup EXIT ERR

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
ANTHROPIC_API_KEY="$1"
AGENT_CONFIG_JSON="$2"
LOCATION="${3:-centralindia}"
SMITHERY_API_KEY="${4:-}"
AGENT_REGISTRY_URL="${5:-http://registry.chat39.com:6900}"
MCP_REGISTRY_URL="${6:-http://registry.chat39.com:7878}"
VM_SIZE="${7:-Standard_B2s}"
PUBLIC_IP_NAME="${8:-}"

if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_CONFIG_JSON" ]; then
    echo -e "${RED}ERROR: Usage: $0 <ANTHROPIC_API_KEY> <AGENT_CONFIG_JSON> [LOCATION] [SMITHERY_API_KEY] [AGENT_REGISTRY_URL] [MCP_REGISTRY_URL] [VM_SIZE] [PUBLIC_IP_NAME]${NC}"
    echo ""
    echo "Example:"
    echo "  $0 sk-ant-xxx scripts/agent_configs/test-3-agents.json centralindia smth-xxx http://registry.chat39.com:6900 http://registry.chat39.com:7878 Standard_B2s"
    exit 1
fi

# Parse and validate agent config
if [ -f "$AGENT_CONFIG_JSON" ]; then
    AGENTS_JSON=$(cat "$AGENT_CONFIG_JSON")
else
    AGENTS_JSON="$AGENT_CONFIG_JSON"
fi

AGENT_COUNT=$(echo "$AGENTS_JSON" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))")
echo "Agents to deploy: $AGENT_COUNT"

# Validate port configuration
echo "Validating port configuration..."
DUPLICATE_PORTS=$(echo "$AGENTS_JSON" | python3 -c "
import json, sys
from collections import Counter
agents = json.load(sys.stdin)
ports = [agent['port'] for agent in agents]
duplicates = [port for port, count in Counter(ports).items() if count > 1]
if duplicates:
    print(' '.join(map(str, duplicates)))
    sys.exit(1)
")

if [ $? -eq 1 ]; then
    echo -e "${RED}ERROR: Duplicate ports found: $DUPLICATE_PORTS${NC}"
    exit 1
fi

echo -e "${GREEN}OK: All ports are in allowed ranges${NC}"

# Extract port list for NSG rules
AGENT_PORT_LIST=$(echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
print(' '.join(str(agent['port']) for agent in agents))
")

# Configuration
RESOURCE_GROUP="nanda-agents-rg"
NSG_NAME="nanda-agents-nsg"
VNET_NAME="nanda-agents-vnet"
SUBNET_NAME="nanda-agents-subnet"
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)
VM_NAME="nanda-multi-${DEPLOYMENT_ID}"

# Clean up old cloud-init files (older than 1 day)
find . -maxdepth 1 -name "cloud-init-*.yaml" -type f -mtime +1 -delete 2>/dev/null || true

# [1/7] Check Azure CLI
echo -e "${YELLOW}[1/7] Checking Azure CLI...${NC}"
if ! command -v az >/dev/null 2>&1; then
    echo -e "${RED}❌ Azure CLI not installed. Install from https://learn.microsoft.com/cli/azure/install-azure-cli${NC}"
    exit 1
fi

if ! az account show >/dev/null 2>&1; then
    echo -e "${RED}❌ Not logged in to Azure. Run 'az login' first.${NC}"
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo -e "${GREEN}✅ Using Azure subscription: $SUBSCRIPTION_ID${NC}"

# [2/7] Ensure resource group
echo -e "${YELLOW}[2/7] Ensuring resource group exists...${NC}"
if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Creating resource group $RESOURCE_GROUP in $LOCATION..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi
echo -e "${GREEN}✅ Resource group ready: $RESOURCE_GROUP${NC}"

# [3/7] Ensure network security group and rules
echo -e "${YELLOW}[3/7] Ensuring network security group exists...${NC}"
if ! az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" >/dev/null 2>&1; then
    echo "Creating network security group $NSG_NAME..."
    az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" --location "$LOCATION" --output none
    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "AllowSSH" --priority 1000 --source-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --output none
fi

PRIORITY=2000
for PORT in $AGENT_PORT_LIST; do
    RULE_NAME="AllowAgentPort${PORT}"
    if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" >/dev/null 2>&1; then
        az network nsg rule create \
            --resource-group "$RESOURCE_GROUP" \
            --nsg-name "$NSG_NAME" \
            --name "$RULE_NAME" \
            --priority $PRIORITY \
            --source-address-prefixes '*' \
            --destination-port-ranges "$PORT" \
            --access Allow \
            --protocol Tcp \
            --output none
        PRIORITY=$((PRIORITY + 1))
    fi
done
echo -e "${GREEN}✅ Network security group ready: $NSG_NAME${NC}"

# [4/7] Ensure virtual network and subnet
echo -e "${YELLOW}[4/7] Ensuring virtual network and subnet exist...${NC}"
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" >/dev/null 2>&1; then
    echo "Creating virtual network $VNET_NAME..."
    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --address-prefix 10.0.0.0/16 \
        --subnet-name "$SUBNET_NAME" \
        --subnet-prefix 10.0.1.0/24 \
        --location "$LOCATION" \
        --output none
fi

az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --output none
echo -e "${GREEN}✅ Virtual network ready: $VNET_NAME / $SUBNET_NAME${NC}"

# [5/7] Create cloud-init configuration
echo -e "${YELLOW}[5/7] Creating cloud-init configuration...${NC}"

# Create the setup script as a separate file first
cat > "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh" <<'SETUPSCRIPT'
#!/bin/bash
exec > /var/log/cloud-init-output.log 2>&1
echo "=== NANDA Multi-Agent Setup Started: DEPLOYMENT_ID_PLACEHOLDER ==="
date

cd /home/azureuser
if [ ! -d nanda-multi-agents ]; then
    sudo -u azureuser git clone https://github.com/projnanda/NEST.git nanda-multi-agents
fi
cd nanda-multi-agents
sudo -u azureuser git fetch --all || true
sudo -u azureuser git checkout main || true
sudo -u azureuser git pull origin main || true

sudo -u azureuser python3 -m venv env
sudo -u azureuser bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"

PUBLIC_IP=""
PUBLIC_IP=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || true)
if [ -z "${PUBLIC_IP}" ]; then
    PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)
fi
if [ -z "${PUBLIC_IP}" ]; then
    PUBLIC_IP=$(curl -s --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)
fi
if [ -z "${PUBLIC_IP}" ]; then
    PUBLIC_IP="0.0.0.0"
fi

echo "Retrieved public IP: ${PUBLIC_IP}"

cat > /tmp/agents_config.json <<"AGENTJSONEOF"
AGENTS_JSON_PLACEHOLDER
AGENTJSONEOF

while IFS= read -r agent_json; do
    AGENT_ID=$(echo "$agent_json" | jq -r '.agent_id')
    AGENT_NAME=$(echo "$agent_json" | jq -r '.agent_name')
    PORT=$(echo "$agent_json" | jq -r '.port')

    HEX_SUFFIX=$(openssl rand -hex 3)
    FULL_AGENT_ID="${AGENT_ID}-${HEX_SUFFIX}"

    echo "Starting agent: ${FULL_AGENT_ID} on port ${PORT}"

    sudo -u azureuser bash -c "cd /home/azureuser/nanda-multi-agents && source env/bin/activate && \
        export ANTHROPIC_API_KEY='ANTHROPIC_KEY_PLACEHOLDER' && \
        export AGENT_ID='${FULL_AGENT_ID}' && \
        export AGENT_NAME='${AGENT_NAME}' && \
        export PUBLIC_URL='http://${PUBLIC_IP}:${PORT}' && \
        export PORT='${PORT}' && \
        export REGISTRY_URL='AGENT_REGISTRY_PLACEHOLDER' && \
        export MCP_REGISTRY_URL='MCP_REGISTRY_PLACEHOLDER' && \
        export SMITHERY_API_KEY='SMITHERY_KEY_PLACEHOLDER' && \
        nohup python3 examples/nanda_agent.py > /home/azureuser/agent_${FULL_AGENT_ID}.log 2>&1 &"

done < <(jq -c '.[]' /tmp/agents_config.json)

echo "=== NANDA Multi-Agent Setup Complete: DEPLOYMENT_ID_PLACEHOLDER ==="
date
SETUPSCRIPT

# Replace placeholders in the script
sed -i '' "s|DEPLOYMENT_ID_PLACEHOLDER|${DEPLOYMENT_ID}|g" "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"
sed -i '' "s|ANTHROPIC_KEY_PLACEHOLDER|${ANTHROPIC_API_KEY}|g" "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"
sed -i '' "s|AGENT_REGISTRY_PLACEHOLDER|${AGENT_REGISTRY_URL}|g" "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"
sed -i '' "s|MCP_REGISTRY_PLACEHOLDER|${MCP_REGISTRY_URL}|g" "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"
sed -i '' "s|SMITHERY_KEY_PLACEHOLDER|${SMITHERY_API_KEY}|g" "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"

# Replace AGENTS_JSON_PLACEHOLDER
python3 <<PYREPLACE
import sys
agents_json = """${AGENTS_JSON}"""
script = open("/tmp/nanda_setup_${DEPLOYMENT_ID}.sh").read()
script = script.replace("AGENTS_JSON_PLACEHOLDER", agents_json)
with open("/tmp/nanda_setup_${DEPLOYMENT_ID}.sh", "w") as f:
    f.write(script)
PYREPLACE

# Base64 encode the script
SCRIPT_B64=$(base64 < "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh")

# Create cloud-init with base64-encoded script
cat > "cloud-init-${DEPLOYMENT_ID}.yaml" <<CLOUDEOF
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
  - echo '${SCRIPT_B64}' | base64 -d > /tmp/nanda_setup.sh
  - chmod +x /tmp/nanda_setup.sh
  - bash /tmp/nanda_setup.sh
CLOUDEOF

rm -f "/tmp/nanda_setup_${DEPLOYMENT_ID}.sh"

# Optional reuse of existing public IP
PUBLIC_IP_ARG=()
if [ -n "$PUBLIC_IP_NAME" ]; then
    echo "Attempting to reuse public IP resource: $PUBLIC_IP_NAME"
    if az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" >/dev/null 2>&1; then
        PUBLIC_IP_ARG=(--public-ip-address "$PUBLIC_IP_NAME")
        echo "Reusing existing public IP: $PUBLIC_IP_NAME"
    else
        echo "Warning: Public IP $PUBLIC_IP_NAME not found in $RESOURCE_GROUP. A new IP will be created."
    fi
fi

# [6/7] Create VM
echo -e "${YELLOW}[6/7] Creating Azure VM...${NC}"
VM_CREATE_CMD=(
    az vm create
    --resource-group "$RESOURCE_GROUP"
    --name "$VM_NAME"
    --location "$LOCATION"
    --size "$VM_SIZE"
    --image Ubuntu2204
    --admin-username azureuser
    --generate-ssh-keys
    --vnet-name "$VNET_NAME"
    --subnet "$SUBNET_NAME"
    --nsg "$NSG_NAME"
    --public-ip-sku Standard
)
if [ ${#PUBLIC_IP_ARG[@]} -gt 0 ]; then
    VM_CREATE_CMD+=( "${PUBLIC_IP_ARG[@]}" )
fi
VM_CREATE_CMD+=(
    --custom-data @"cloud-init-${DEPLOYMENT_ID}.yaml"
    --tags Project=NANDA Type=MultiAgent DeploymentId="$DEPLOYMENT_ID"
    --output none
)
"${VM_CREATE_CMD[@]}"

echo -e "${GREEN}✅ VM creation requested: $VM_NAME${NC}"

# [7/7] Retrieve deployment details
echo -e "${YELLOW}[7/7] Retrieving VM details...${NC}"
PUBLIC_IP=$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query publicIps -o tsv)

echo "Waiting for agents to start (180 seconds)..."
sleep 180

# Cloud-init file will be cleaned up by trap on exit

# Summary
echo ""
echo -e "${GREEN}🎉 Azure Multi-Agent Deployment Complete${NC}"
echo "============================================="
echo "Deployment ID: $DEPLOYMENT_ID"
echo "VM Name: $VM_NAME"
echo "Location: $LOCATION"
echo "VM Size: $VM_SIZE"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "🤖 Agent URLs:"
AGENTS_JSON_ENV="$AGENTS_JSON" PUBLIC_IP_SUMMARY="$PUBLIC_IP" python3 - <<'PY'
import json, os
public_ip = os.environ.get('PUBLIC_IP_SUMMARY', '0.0.0.0')
agents = json.loads(os.environ['AGENTS_JSON_ENV'])
for agent in agents:
    print(f"  {agent['agent_id']}: http://{public_ip}:{agent['port']}/a2a")
PY

echo ""
echo "📊 Monitor agents:"
echo "  ssh azureuser@$PUBLIC_IP 'ps aux | grep nanda_agent'"
echo ""
echo "📋 View logs:"
echo "  ssh azureuser@$PUBLIC_IP 'tail -f /home/azureuser/agent_*.log'"
echo ""
echo "🔄 Restart agents (kill and restart):"
echo "  ssh azureuser@$PUBLIC_IP 'pkill -f nanda_agent.py; cd /home/azureuser/nanda-multi-agents && source env/bin/activate && nohup python3 examples/nanda_agent.py &'"
echo ""
echo "🛑 Delete VM:"
echo "  az vm delete --resource-group $RESOURCE_GROUP --name $VM_NAME --yes"
echo ""
echo "🗑️  Delete resource group:"
echo "  az group delete --name $RESOURCE_GROUP --yes"
