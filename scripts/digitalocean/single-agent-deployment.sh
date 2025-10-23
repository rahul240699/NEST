#!/bin/bash

# CONFIGURABLE DigitalOcean Droplet + NANDA Agent Deployment Script
# This script creates a DigitalOcean droplet and deploys a fully configurable modular NANDA agent
# Usage: bash digitalocean-single-agent-deployment.sh <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> [REGISTRY_URL] [PORT] [REGION] [DROPLET_SIZE]

set -e

# Parse arguments
AGENT_ID="$1"
ANTHROPIC_API_KEY="$2"
AGENT_NAME="$3"
DOMAIN="$4"
SPECIALIZATION="$5"
DESCRIPTION="$6"
CAPABILITIES="$7"
REGISTRY_URL="${8:-}"
PORT="${9:-6000}"
REGION="${10:-nyc1}"
DROPLET_SIZE="${11:-s-1vcpu-1gb}"

# Validate inputs
if [ -z "$AGENT_ID" ] || [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_NAME" ] || [ -z "$DOMAIN" ] || [ -z "$SPECIALIZATION" ] || [ -z "$DESCRIPTION" ] || [ -z "$CAPABILITIES" ]; then
    echo "❌ Usage: $0 <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> [REGISTRY_URL] [PORT] [REGION] [DROPLET_SIZE]"
    echo ""
    echo "Example:"
    echo "  $0 data-scientist sk-ant-xxxxx \"Data Scientist\" \"data analysis\" \"analytical and precise AI assistant\" \"I specialize in data analysis, statistics, and machine learning.\" \"data analysis,statistics,machine learning,Python,R\" \"https://registry.example.com\" 6000 nyc1 s-1vcpu-1gb"
    echo ""
    echo "Parameters:"
    echo "  AGENT_ID: Unique identifier for the agent"
    echo "  ANTHROPIC_API_KEY: Your Anthropic API key"
    echo "  AGENT_NAME: Display name for the agent"
    echo "  DOMAIN: Primary domain/field of expertise"
    echo "  SPECIALIZATION: Brief description of agent's role"
    echo "  DESCRIPTION: Detailed description of the agent"
    echo "  CAPABILITIES: Comma-separated list of capabilities"
    echo "  REGISTRY_URL: Optional registry URL for agent discovery"
    echo "  PORT: Port for agent HTTP server (default: 6000)"
    echo "  REGION: DigitalOcean region (default: nyc1)"
    echo "  DROPLET_SIZE: Droplet size slug (default: s-1vcpu-1gb)"
    echo ""
    echo "Common DigitalOcean regions: nyc1, nyc3, sfo3, ams3, sgp1, lon1, fra1, tor1, blr1"
    echo "Common droplet sizes: s-1vcpu-1gb, s-1vcpu-2gb, s-2vcpu-2gb, s-2vcpu-4gb"
    exit 1
fi

echo "🚀 Configurable DigitalOcean + NANDA Agent Deployment"
echo "====================================================="
echo "Agent ID: $AGENT_ID"
echo "Agent Name: $AGENT_NAME"
echo "Domain: $DOMAIN"
echo "Specialization: $SPECIALIZATION"
echo "Capabilities: $CAPABILITIES"
echo "Registry URL: ${REGISTRY_URL:-"None"}"
echo "Port: $PORT"
echo "Region: $REGION"
echo "Droplet Size: $DROPLET_SIZE"
echo ""

# Configuration
SSH_KEY_NAME="nanda-agent-key"
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)
IMAGE_SLUG="ubuntu-22-04-x64"

# Check doctl (DigitalOcean CLI) installation
echo "[1/7] Checking DigitalOcean CLI (doctl)..."
if ! command -v doctl &> /dev/null; then
    echo "❌ doctl not installed. Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/"
    exit 1
fi

# Check authentication
if ! doctl account get >/dev/null 2>&1; then
    echo "❌ doctl not authenticated. Run 'doctl auth init' first."
    exit 1
fi
echo "✅ DigitalOcean CLI authenticated"

# Setup SSH key
echo "[2/7] Setting up SSH key..."
if [ ! -f "${SSH_KEY_NAME}" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_NAME" -N "" -C "nanda-agent-$DEPLOYMENT_ID"
fi

# Upload SSH key to DigitalOcean if not exists
SSH_KEY_ID=$(doctl compute ssh-key list --format ID,Name --no-header | grep "$SSH_KEY_NAME" | awk '{print $1}' || echo "")
if [ -z "$SSH_KEY_ID" ]; then
    echo "Uploading SSH key to DigitalOcean..."
    SSH_KEY_ID=$(doctl compute ssh-key create "$SSH_KEY_NAME" --public-key-file "${SSH_KEY_NAME}.pub" --format ID --no-header)
fi
echo "✅ SSH key ID: $SSH_KEY_ID"

# Setup firewall
echo "[3/7] Setting up firewall..."
FIREWALL_NAME="nanda-agent-fw-${DEPLOYMENT_ID}"

# Create firewall with SSH and agent port
FIREWALL_ID=$(doctl compute firewall create \
    --name "$FIREWALL_NAME" \
    --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0 protocol:tcp,ports:${PORT},address:0.0.0.0/0" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0" \
    --format ID --no-header)

echo "✅ Firewall created: $FIREWALL_ID"

# Create user data script
echo "[4/7] Creating user data script..."
cat > "user_data_${AGENT_ID}_${DEPLOYMENT_ID}.sh" << 'USERDATA_EOF'
#!/bin/bash
exec > /var/log/user-data.log 2>&1

echo "=== NANDA Agent Setup Started: ${AGENT_ID} ==="
date

# Update system and install dependencies
apt-get update -y
apt-get install -y python3 python3-venv python3-pip git curl

# Setup project as root (DigitalOcean uses root by default)
cd /root
git clone https://github.com/projnanda/NEST.git nanda-agent-${AGENT_ID}
cd nanda-agent-${AGENT_ID}

# Create virtual environment and install
python3 -m venv env
bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"

# Get public IP using DigitalOcean metadata service
echo "Getting public IP address from metadata service..."
for attempt in {1..10}; do
    PUBLIC_IP=$(curl -s --connect-timeout 5 --max-time 10 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null)
    
    if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Retrieved public IP: $PUBLIC_IP"
        break
    fi
    echo "Attempt $attempt failed, retrying..."
    sleep 3
done

if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: Could not retrieve public IP after 10 attempts"
    exit 1
fi

# Start the agent with all configuration
echo "Starting NANDA agent with PUBLIC_URL: http://$PUBLIC_IP:${PORT}"
bash -c "
    cd /root/nanda-agent-${AGENT_ID}
    source env/bin/activate
    export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'
    export AGENT_ID='${AGENT_ID}'
    export AGENT_NAME='${AGENT_NAME}'
    export AGENT_DOMAIN='${DOMAIN}'
    export AGENT_SPECIALIZATION='${SPECIALIZATION}'
    export AGENT_DESCRIPTION='${DESCRIPTION}'
    export AGENT_CAPABILITIES='${CAPABILITIES}'
    export REGISTRY_URL='${REGISTRY_URL}'
    export PUBLIC_URL='http://$PUBLIC_IP:${PORT}'
    export PORT='${PORT}'
    nohup python3 examples/nanda_agent.py > agent.log 2>&1 &
"

echo "=== NANDA Agent Setup Complete: ${AGENT_ID} ==="
echo "Agent URL: http://$PUBLIC_IP:${PORT}/a2a"
USERDATA_EOF

# Substitute variables in user data
sed -i.bak \
    -e "s/\${AGENT_ID}/$AGENT_ID/g" \
    -e "s/\${ANTHROPIC_API_KEY}/$ANTHROPIC_API_KEY/g" \
    -e "s/\${AGENT_NAME}/$AGENT_NAME/g" \
    -e "s/\${DOMAIN}/$DOMAIN/g" \
    -e "s/\${SPECIALIZATION}/$SPECIALIZATION/g" \
    -e "s/\${DESCRIPTION}/$DESCRIPTION/g" \
    -e "s/\${CAPABILITIES}/$CAPABILITIES/g" \
    -e "s/\${REGISTRY_URL}/$REGISTRY_URL/g" \
    -e "s/\${PORT}/$PORT/g" \
    "user_data_${AGENT_ID}_${DEPLOYMENT_ID}.sh"

# Launch droplet
echo "[5/7] Launching DigitalOcean droplet..."
DROPLET_ID=$(doctl compute droplet create "nanda-agent-$AGENT_ID" \
    --region "$REGION" \
    --size "$DROPLET_SIZE" \
    --image "$IMAGE_SLUG" \
    --ssh-keys "$SSH_KEY_ID" \
    --user-data-file "user_data_${AGENT_ID}_${DEPLOYMENT_ID}.sh" \
    --tag-names "NANDA,agent,single" \
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

echo "[7/7] Waiting for agent deployment (2-3 minutes)..."
sleep 120

# Cleanup
rm "user_data_${AGENT_ID}_${DEPLOYMENT_ID}.sh" "user_data_${AGENT_ID}_${DEPLOYMENT_ID}.sh.bak"

echo ""
echo "🎉 NANDA Agent Deployment Complete!"
echo "=================================="
echo "Droplet ID: $DROPLET_ID"
echo "Public IP: $PUBLIC_IP"
echo "Agent URL: http://$PUBLIC_IP:$PORT/a2a"
echo "Firewall ID: $FIREWALL_ID"
echo ""
echo "🤖 Agent ID for A2A Communication: ${AGENT_ID}-[6-char-hex]"
echo ""
echo "📞 Use this agent in A2A messages:"
echo "   @${AGENT_ID}-[hex] your message here"
echo "   (The actual hex suffix is generated at runtime)"

echo ""
echo "🧪 Test your agent (direct communication):"
echo "curl -X POST http://$PUBLIC_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"Hello! What can you help me with?\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test123\"}'"

echo ""
echo "🔐 SSH Access:"
echo "ssh -i ${SSH_KEY_NAME} root@$PUBLIC_IP"
echo ""
echo "📊 View agent logs:"
echo "ssh -i ${SSH_KEY_NAME} root@$PUBLIC_IP 'tail -f /root/nanda-agent-${AGENT_ID}/agent.log'"
echo ""
echo "🛑 To terminate:"
echo "doctl compute droplet delete $DROPLET_ID"
echo "doctl compute firewall delete $FIREWALL_ID"
