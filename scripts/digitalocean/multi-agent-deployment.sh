#!/bin/bash

# CONFIGURABLE DigitalOcean Multi-Agent Deployment Script
# This script creates a DigitalOcean droplet and deploys multiple fully configurable modular NANDA agents
# Usage: bash digitalocean-multi-agent-deployment.sh <ANTHROPIC_API_KEY> <AGENT_CONFIG_JSON> [REGISTRY_URL] [REGION] [DROPLET_SIZE]

set -e

# Parse arguments
ANTHROPIC_API_KEY="$1"
AGENT_CONFIG_JSON="$2"
REGISTRY_URL="${3:-http://registry.chat39.com:6900}"
REGION="${4:-nyc1}"
DROPLET_SIZE="${5:-s-2vcpu-4gb}"  # 4GB for multiple agents

# Validation
if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_CONFIG_JSON" ]; then
    echo "❌ Usage: $0 <ANTHROPIC_API_KEY> <AGENT_CONFIG_JSON> [REGISTRY_URL] [REGION] [DROPLET_SIZE]"
    echo ""
    echo "Example:"
    echo "  $0 sk-ant-xxxxx ./scripts/agent_configs/group-01-business-and-finance-experts.json \"http://registry.chat39.com:6900\" nyc1 s-2vcpu-4gb"
    echo ""
    echo "Parameters:"
    echo "  ANTHROPIC_API_KEY: Your Anthropic API key"
    echo "  AGENT_CONFIG_JSON: Path to JSON file or JSON string with agent configurations"
    echo "  REGISTRY_URL: Registry URL for agent discovery (default: http://registry.chat39.com:6900)"
    echo "  REGION: DigitalOcean region (default: nyc1)"
    echo "  DROPLET_SIZE: Droplet size slug (default: s-2vcpu-4gb for 4GB RAM)"
    echo ""
    echo "Common DigitalOcean regions: nyc1, nyc3, sfo3, ams3, sgp1, lon1, fra1, tor1, blr1"
    echo "Common droplet sizes: s-1vcpu-2gb (2GB), s-2vcpu-4gb (4GB), s-4vcpu-8gb (8GB)"
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

# Validate instance type for agent count
if [ "$AGENT_COUNT" -gt 5 ] && [ "$DROPLET_SIZE" = "s-1vcpu-2gb" ]; then
    echo "⚠️  WARNING: s-1vcpu-2gb may be insufficient for $AGENT_COUNT agents. Consider s-2vcpu-4gb or larger."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Validate port uniqueness
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
    echo "❌ Duplicate ports found: $DUPLICATE_PORTS"
    exit 1
fi

# Configuration
SSH_KEY_NAME="nanda-multi-agent-key"
IMAGE_SLUG="ubuntu-22-04-x64"
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)

echo "🚀 Configurable DigitalOcean Multi-Agent Deployment"
echo "===================================================="
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Agent Count: $AGENT_COUNT"
echo "Registry URL: $REGISTRY_URL"
echo "Region: $REGION"
echo "Droplet Size: $DROPLET_SIZE"
echo ""

# Check DigitalOcean CLI
echo "[1/7] Checking DigitalOcean CLI (doctl)..."
if ! command -v doctl &> /dev/null; then
    echo "❌ doctl not installed. Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/"
    exit 1
fi

if ! doctl account get >/dev/null 2>&1; then
    echo "❌ doctl not authenticated. Run 'doctl auth init' first."
    exit 1
fi
echo "✅ DigitalOcean CLI authenticated"

# Setup SSH key
echo "[2/7] Setting up SSH key..."
if [ ! -f "${SSH_KEY_NAME}" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_NAME" -N "" -C "nanda-multi-agent-$DEPLOYMENT_ID"
fi

SSH_KEY_ID=$(doctl compute ssh-key list --format ID,Name --no-header | grep "$SSH_KEY_NAME" | awk '{print $1}' || echo "")
if [ -z "$SSH_KEY_ID" ]; then
    echo "Uploading SSH key to DigitalOcean..."
    SSH_KEY_ID=$(doctl compute ssh-key create "$SSH_KEY_NAME" --public-key-file "${SSH_KEY_NAME}.pub" --format ID --no-header)
fi
echo "✅ SSH key ID: $SSH_KEY_ID"

# Setup firewall
echo "[3/7] Setting up firewall..."
FIREWALL_NAME="nanda-multi-agent-fw-${DEPLOYMENT_ID}"

# Get agent ports for firewall rules
AGENT_PORTS=$(echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
ports = [str(agent['port']) for agent in agents]
print(','.join(ports))
")

# Build firewall inbound rules (SSH + all agent ports)
INBOUND_RULES="protocol:tcp,ports:22,address:0.0.0.0/0"
IFS=',' read -ra PORTS <<< "$AGENT_PORTS"
for PORT in "${PORTS[@]}"; do
    INBOUND_RULES="${INBOUND_RULES} protocol:tcp,ports:${PORT},address:0.0.0.0/0"
done

# Create firewall
FIREWALL_ID=$(doctl compute firewall create \
    --name "$FIREWALL_NAME" \
    --inbound-rules "$INBOUND_RULES" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0" \
    --format ID --no-header)

echo "✅ Firewall created with ports: SSH, $AGENT_PORTS"
echo "✅ Firewall ID: $FIREWALL_ID"

# Create improved user data script with supervisor
echo "[4/7] Creating improved user data script..."
cat > "user_data_multi_${DEPLOYMENT_ID}.sh" << EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1

echo "=== NANDA Multi-Agent Setup Started: $DEPLOYMENT_ID ==="
date

# Update system and install dependencies
apt-get update -y
apt-get install -y python3 python3-venv python3-pip git curl jq supervisor

# Setup project as root
cd /root
git clone https://github.com/projnanda/NEST.git nanda-multi-agents-$DEPLOYMENT_ID
cd nanda-multi-agents-$DEPLOYMENT_ID

# Create virtual environment and install
python3 -m venv env
bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"

# Get public IP using DigitalOcean metadata service
echo "Getting public IP address from metadata service..."
for attempt in {1..10}; do
    PUBLIC_IP=\$(curl -s --connect-timeout 5 --max-time 10 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null)
    
    if [ -n "\$PUBLIC_IP" ] && [[ \$PUBLIC_IP =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$ ]]; then
        echo "Retrieved public IP: \$PUBLIC_IP"
        break
    fi
    echo "Attempt \$attempt failed, retrying..."
    sleep 3
done

if [ -z "\$PUBLIC_IP" ]; then
    echo "ERROR: Could not retrieve public IP after 10 attempts"
    exit 1
fi

# Save agent configuration
cat > /tmp/agents_config.json << 'AGENTS_EOF'
$AGENTS_JSON
AGENTS_EOF

# Create supervisor configuration for each agent
echo "Creating supervisor configurations..."
mkdir -p /etc/supervisor/conf.d

while IFS= read -r agent_config; do
    AGENT_ID=\$(echo "\$agent_config" | jq -r '.agent_id')
    AGENT_NAME=\$(echo "\$agent_config" | jq -r '.agent_name')
    DOMAIN=\$(echo "\$agent_config" | jq -r '.domain')
    SPECIALIZATION=\$(echo "\$agent_config" | jq -r '.specialization')
    DESCRIPTION=\$(echo "\$agent_config" | jq -r '.description')
    CAPABILITIES=\$(echo "\$agent_config" | jq -c '.capabilities')
    PORT=\$(echo "\$agent_config" | jq -r '.port')
    
    echo "Configuring supervisor for agent: \$AGENT_ID"
    
    # Create supervisor configuration file
    cat > "/etc/supervisor/conf.d/agent_\$AGENT_ID.conf" << SUPERVISOR_EOF
[program:agent_\$AGENT_ID]
command=/root/nanda-multi-agents-$DEPLOYMENT_ID/env/bin/python examples/nanda_agent.py
directory=/root/nanda-multi-agents-$DEPLOYMENT_ID
user=root
autostart=true
autorestart=true
startretries=3
stderr_logfile=/var/log/agent_\$AGENT_ID.err.log
stdout_logfile=/var/log/agent_\$AGENT_ID.out.log
environment=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY",AGENT_ID="\$AGENT_ID",AGENT_NAME="\$AGENT_NAME",AGENT_DOMAIN="\$DOMAIN",AGENT_SPECIALIZATION="\$SPECIALIZATION",AGENT_DESCRIPTION="\$DESCRIPTION",AGENT_CAPABILITIES='\$CAPABILITIES',REGISTRY_URL="$REGISTRY_URL",PUBLIC_URL="http://\$PUBLIC_IP:\$PORT",PORT="\$PORT"

SUPERVISOR_EOF

    echo "✅ Supervisor config created for agent \$AGENT_ID on port \$PORT"
    
done < <(cat /tmp/agents_config.json | jq -c '.[]')

# Start supervisor and wait for all agents
echo "Starting supervisor..."
systemctl enable supervisor
systemctl start supervisor
supervisorctl reread
supervisorctl update

# Wait for all agents to start
echo "Waiting for all agents to start..."
sleep 30

# Verify all agents are running
echo "Verifying agent status..."
supervisorctl status

echo "=== NANDA Multi-Agent Setup Complete: $DEPLOYMENT_ID ==="
echo "All agents managed by supervisor on: \$PUBLIC_IP"
EOF

# Launch droplet
echo "[5/7] Launching DigitalOcean droplet..."
DROPLET_ID=$(doctl compute droplet create "nanda-multi-agent-$DEPLOYMENT_ID" \
    --region "$REGION" \
    --size "$DROPLET_SIZE" \
    --image "$IMAGE_SLUG" \
    --ssh-keys "$SSH_KEY_ID" \
    --user-data-file "user_data_multi_${DEPLOYMENT_ID}.sh" \
    --tag-names "NANDA,multi-agent" \
    --format ID --no-header \
    --wait)

echo "✅ Droplet created: $DROPLET_ID"

# Wait for droplet to be active and get IP
echo "[6/7] Waiting for droplet to be active..."
sleep 10

PUBLIC_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
echo "✅ Public IP: $PUBLIC_IP"

# Attach firewall to droplet
doctl compute firewall add-droplets "$FIREWALL_ID" --droplet-ids "$DROPLET_ID"
echo "✅ Firewall attached to droplet"

echo "[7/7] Waiting for multi-agent deployment (2-3 minutes)..."
sleep 150

# Cleanup
rm "user_data_multi_${DEPLOYMENT_ID}.sh"

# Health check all agents
echo ""
echo "🔍 Performing health checks..."
echo "$AGENTS_JSON" | python3 -c "
import json, sys
try:
    import requests
    agents = json.load(sys.stdin)
    for agent in agents:
        url = f'http://$PUBLIC_IP:{agent[\"port\"]}/health'
        try:
            response = requests.get(url, timeout=5)
            if response.status_code == 200:
                print(f'✅ {agent[\"agent_id\"]}: Healthy')
            else:
                print(f'⚠️  {agent[\"agent_id\"]}: HTTP {response.status_code}')
        except Exception as e:
            print(f'❌ {agent[\"agent_id\"]}: {str(e)}')
except ImportError:
    print('Health check skipped (requests not available)')
" 2>/dev/null || echo "Health check skipped (requests not available)"

echo ""
echo "🎉 NANDA Multi-Agent Deployment Complete!"
echo "=========================================="
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Droplet ID: $DROPLET_ID"
echo "Public IP: $PUBLIC_IP"
echo "Firewall ID: $FIREWALL_ID"

# Display agent URLs
echo ""
echo "🤖 Agent URLs:"
echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
for agent in agents:
    print(f\"  {agent['agent_id']}: http://$PUBLIC_IP:{agent['port']}/a2a\")
"

echo ""
echo "🧪 Test an agent (direct communication):"
FIRST_PORT=$(echo "$AGENTS_JSON" | python3 -c "import json, sys; agents = json.load(sys.stdin); print(agents[0]['port']) if agents else print('6000')")
echo "curl -X POST http://$PUBLIC_IP:$FIRST_PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"Hello! What can you help me with?\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test123\"}'"

echo ""
echo "🔐 SSH Access:"
echo "ssh -i ${SSH_KEY_NAME} root@$PUBLIC_IP"

echo ""
echo "📊 Monitor agents:"
echo "ssh -i ${SSH_KEY_NAME} root@$PUBLIC_IP 'supervisorctl status'"

echo ""
echo "🔄 Restart all agents:"
echo "ssh -i ${SSH_KEY_NAME} root@$PUBLIC_IP 'supervisorctl restart all'"

echo ""
echo "🛑 To terminate:"
echo "doctl compute droplet delete $DROPLET_ID"
echo "doctl compute firewall delete $FIREWALL_ID"
