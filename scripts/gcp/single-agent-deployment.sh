#!/bin/bash

# GCP Compute Engine + NANDA Agent Deployment Script
# This script creates a GCP Compute Engine instance and deploys a fully configurable modular NANDA agent
# Usage: bash single-agent-deployment.sh <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> <SMITHERY_API_KEY> [REGISTRY_URL] [MCP_REGISTRY_URL] [PORT] [ZONE] [MACHINE_TYPE]

set -e

# Parse arguments
AGENT_ID="$1"
ANTHROPIC_API_KEY="$2"
AGENT_NAME="$3"
DOMAIN="$4"
SPECIALIZATION="$5"
DESCRIPTION="$6"
CAPABILITIES="$7"
SMITHERY_API_KEY="$8"
REGISTRY_URL="${9:-}"
MCP_REGISTRY_URL="${10:-}"
PORT="${11:-6000}"
ZONE="${12:-us-central1-a}"
MACHINE_TYPE="${13:-e2-micro}"

# Validate inputs
if [ -z "$AGENT_ID" ] || [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_NAME" ] || [ -z "$DOMAIN" ] || [ -z "$SPECIALIZATION" ] || [ -z "$DESCRIPTION" ] || [ -z "$CAPABILITIES" ] || [ -z "$SMITHERY_API_KEY" ]; then
    echo "❌ Usage: $0 <AGENT_ID> <ANTHROPIC_API_KEY> <AGENT_NAME> <DOMAIN> <SPECIALIZATION> <DESCRIPTION> <CAPABILITIES> <SMITHERY_API_KEY> [REGISTRY_URL] [MCP_REGISTRY_URL] [PORT] [ZONE] [MACHINE_TYPE]"
    echo ""
    echo "Example:"
    echo "  $0 data-scientist sk-ant-xxxxx \"Data Scientist\" \"data analysis\" \"analytical and precise AI assistant\" \"I specialize in data analysis, statistics, and machine learning.\" \"data analysis,statistics,machine learning,Python,R\" smithery-key-xxxxx \"https://registry.example.com\" \"https://d9750825b5c6.ngrok-free.app\" 6000 us-central1-a e2-micro"
    echo ""
    echo "Parameters:"
    echo "  AGENT_ID: Unique identifier for the agent"
    echo "  ANTHROPIC_API_KEY: Your Anthropic API key"
    echo "  AGENT_NAME: Display name for the agent"
    echo "  DOMAIN: Primary domain/field of expertise"
    echo "  SPECIALIZATION: Brief description of agent's role"
    echo "  DESCRIPTION: Detailed description of the agent"
    echo "  CAPABILITIES: Comma-separated list of capabilities"
    echo "  SMITHERY_API_KEY: Your Smithery API key for MCP server access"
    echo "  REGISTRY_URL: Optional registry URL for agent discovery"
    echo "  MCP_REGISTRY_URL: Optional MCP registry URL for NANDA MCP servers"
    echo "  PORT: Port number (default: 6000)"
    echo "  ZONE: GCP zone (default: us-central1-a)"
    echo "  MACHINE_TYPE: GCP machine type (default: e2-micro)"
    exit 1
fi

# Validate port is in allowed ranges
validate_port() {
    local port=$1
    # Allowed port ranges: 6000-6100, 7000-7100, 8000-8100, 9000-9100, 10000-10100, 11000-11100, 12000-12100, 13000-13100, 14000-14100, 15000-15100
    if { [ "$port" -ge 6000 ] && [ "$port" -le 6100 ]; } || \
       { [ "$port" -ge 7000 ] && [ "$port" -le 7100 ]; } || \
       { [ "$port" -ge 8000 ] && [ "$port" -le 8100 ]; } || \
       { [ "$port" -ge 9000 ] && [ "$port" -le 9100 ]; } || \
       { [ "$port" -ge 10000 ] && [ "$port" -le 10100 ]; } || \
       { [ "$port" -ge 11000 ] && [ "$port" -le 11100 ]; } || \
       { [ "$port" -ge 12000 ] && [ "$port" -le 12100 ]; } || \
       { [ "$port" -ge 13000 ] && [ "$port" -le 13100 ]; } || \
       { [ "$port" -ge 14000 ] && [ "$port" -le 14100 ]; } || \
       { [ "$port" -ge 15000 ] && [ "$port" -le 15100 ]; }; then
        return 0
    else
        return 1
    fi
}

if ! validate_port "$PORT"; then
    echo "❌ Error: Port $PORT is not in allowed ranges!"
    echo "Allowed port ranges: 6000-6100, 7000-7100, 8000-8100, 9000-9100, 10000-10100, 11000-11100, 12000-12100, 13000-13100, 14000-14100, 15000-15100"
    exit 1
fi

echo "🚀 GCP Compute Engine + NANDA Agent Deployment"
echo "=============================================="
echo "Agent ID: $AGENT_ID"
echo "Agent Name: $AGENT_NAME"
echo "Domain: $DOMAIN"
echo "Specialization: $SPECIALIZATION"
echo "Capabilities: $CAPABILITIES"
echo "Smithery API Key: ${SMITHERY_API_KEY:0:10}..."
echo "Registry URL: ${REGISTRY_URL:-"None"}"
echo "MCP Registry URL: ${MCP_REGISTRY_URL:-"None"}"
echo "Port: $PORT"
echo "Zone: $ZONE"
echo "Machine Type: $MACHINE_TYPE"
echo ""

# Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
FIREWALL_RULE_NAME="nanda-agents-rule"
NETWORK_TAG="nanda-agents"

# Check gcloud configuration
echo "[1/6] Checking gcloud configuration..."
if [ -z "$PROJECT_ID" ]; then
    echo "❌ GCP project not configured. Run 'gcloud config set project YOUR_PROJECT_ID' first."
    exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 >/dev/null 2>&1; then
    echo "❌ Not authenticated with gcloud. Run 'gcloud auth login' first."
    exit 1
fi

echo "✅ Using GCP project: $PROJECT_ID"

# Setup firewall rule
echo "[2/6] Setting up firewall rules..."
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" >/dev/null 2>&1; then
    echo "Creating firewall rule for NANDA agents..."
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:22,tcp:6000-6100 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="$NETWORK_TAG" \
        --description="Firewall rule for NANDA agents"
else
    echo "Firewall rule already exists"
fi

echo "✅ Firewall rule: $FIREWALL_RULE_NAME"

# Setup SSH key (GCP uses project-wide SSH keys by default)
echo "[3/6] Setting up SSH access..."
SSH_KEY_FILE="$HOME/.ssh/gcp_nanda_key"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Creating SSH key pair..."
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_FILE" -N "" -C "nanda-gcp-key"
    
    # Add public key to GCP project metadata
    gcloud compute project-info add-metadata \
        --metadata-from-file ssh-keys=<(gcloud compute project-info describe \
        --format="value(commonInstanceMetadata.items[key=ssh-keys].value)" && \
        echo "ubuntu:$(cat ${SSH_KEY_FILE}.pub)")
fi
echo "✅ SSH key configured"

# Create startup script
echo "[4/6] Creating startup script..."
cat > "startup_script_${AGENT_ID}.sh" << 'STARTUP_EOF'
#!/bin/bash
exec > /var/log/startup-script.log 2>&1

echo "=== NANDA Agent Setup Started on GCP ==="
date

# Update system and install dependencies (optimized for speed)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq -y
apt-get install -qq -y --no-install-recommends python3 python3-venv python3-pip git curl

# Setup project as ubuntu user
cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/projnanda/NEST.git nanda-agent-AGENT_ID_PLACEHOLDER
cd nanda-agent-AGENT_ID_PLACEHOLDER

# Fetch all remote branches and ensure we're on main
echo "Fetching all remote branches..."
sudo -u ubuntu git fetch --all

# Use main branch (MCP tooling will be merged there)
echo "Available branches:"
sudo -u ubuntu git branch -a
echo "Current branch before checkout:"
sudo -u ubuntu git branch
echo "Checking out main branch..."
sudo -u ubuntu git checkout main
sudo -u ubuntu git pull origin main
echo "Successfully on main branch with latest changes"
sudo -u ubuntu git branch

# Create virtual environment and install (optimized)
sudo -u ubuntu python3 -m venv env
sudo -u ubuntu bash -c "source env/bin/activate && pip install --upgrade pip --quiet && pip install -e . --quiet && pip install anthropic --quiet"

# Configure the modular agent with all environment variables
sudo -u ubuntu sed -i'' "s|PORT = 6000|PORT = PORT_PLACEHOLDER|" examples/nanda_agent.py

# Get external IP from GCP metadata
echo "Getting external IP address from GCP metadata..."
for attempt in {1..5}; do
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    if [ -n "$EXTERNAL_IP" ] && [[ $EXTERNAL_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Retrieved external IP: $EXTERNAL_IP"
        break
    fi
    echo "Attempt $attempt failed, retrying..."
    sleep 3
done

if [ -z "$EXTERNAL_IP" ]; then
    echo "ERROR: Could not retrieve external IP"
    exit 1
fi

# Start the agent with all configuration
echo "Starting NANDA agent with PUBLIC_URL: http://$EXTERNAL_IP:PORT_PLACEHOLDER"
sudo -u ubuntu bash -c "
    cd /home/ubuntu/nanda-agent-AGENT_ID_PLACEHOLDER
    source env/bin/activate
    export ANTHROPIC_API_KEY='ANTHROPIC_API_KEY_PLACEHOLDER'
    export SMITHERY_API_KEY='SMITHERY_API_KEY_PLACEHOLDER'
    export AGENT_ID='AGENT_ID_PLACEHOLDER'
    export AGENT_NAME='AGENT_NAME_PLACEHOLDER'
    export AGENT_DOMAIN='DOMAIN_PLACEHOLDER'
    export AGENT_SPECIALIZATION='SPECIALIZATION_PLACEHOLDER'
    export AGENT_DESCRIPTION='DESCRIPTION_PLACEHOLDER'
    export AGENT_CAPABILITIES='CAPABILITIES_PLACEHOLDER'
    export REGISTRY_URL='REGISTRY_URL_PLACEHOLDER'
    export MCP_REGISTRY_URL='MCP_REGISTRY_URL_PLACEHOLDER'
    # Get the external IP dynamically at runtime
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    export PUBLIC_URL="http://$EXTERNAL_IP:PORT_PLACEHOLDER"
    export PORT='PORT_PLACEHOLDER'
    nohup python3 examples/nanda_agent.py > agent.log 2>&1 &
"

echo "=== NANDA Agent Setup Complete on GCP ==="
echo "Agent URL: http://\$EXTERNAL_IP:PORT_PLACEHOLDER/a2a"
STARTUP_EOF

# Replace placeholders in startup script
sed -i '' "s|AGENT_ID_PLACEHOLDER|$AGENT_ID|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|PORT_PLACEHOLDER|$PORT|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|ANTHROPIC_API_KEY_PLACEHOLDER|$ANTHROPIC_API_KEY|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|SMITHERY_API_KEY_PLACEHOLDER|$SMITHERY_API_KEY|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|AGENT_NAME_PLACEHOLDER|$AGENT_NAME|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|SPECIALIZATION_PLACEHOLDER|$SPECIALIZATION|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|DESCRIPTION_PLACEHOLDER|$DESCRIPTION|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|CAPABILITIES_PLACEHOLDER|$CAPABILITIES|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|REGISTRY_URL_PLACEHOLDER|$REGISTRY_URL|g" "startup_script_${AGENT_ID}.sh"
sed -i '' "s|MCP_REGISTRY_URL_PLACEHOLDER|$MCP_REGISTRY_URL|g" "startup_script_${AGENT_ID}.sh"

# Launch Compute Engine instance
echo "[5/6] Launching Compute Engine instance..."
INSTANCE_NAME="nanda-agent-$AGENT_ID"

gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --network-interface=network-tier=PREMIUM,subnet=default \
    --maintenance-policy=MIGRATE \
    --provisioning-model=STANDARD \
    --service-account="$(gcloud iam service-accounts list --filter="displayName:Compute Engine default service account" --format="value(email)")" \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append \
    --tags="$NETWORK_TAG" \
    --create-disk=auto-delete=yes,boot=yes,device-name="$INSTANCE_NAME",image=projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20251002,mode=rw,size=20,type=projects/$PROJECT_ID/zones/$ZONE/diskTypes/pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=project=nanda,type=agent \
    --reservation-affinity=any \
    --metadata-from-file startup-script="startup_script_${AGENT_ID}.sh"

echo "✅ Instance launched: $INSTANCE_NAME"

# Wait for instance to be running
echo "[6/6] Waiting for instance and deployment..."
echo "Waiting for instance to be in RUNNING state..."
while [[ $(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)") != "RUNNING" ]]; do
    echo "Instance status: $(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)")"
    sleep 10
done

EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

echo "Waiting for agent deployment (4-5 minutes)..."
echo "This includes system updates, dependency installation, and agent startup..."

# Wait with progress indicator
for i in {1..24}; do
    echo -n "."
    sleep 10
    
    # Check if agent is responding after 3 minutes
    if [ $i -eq 18 ]; then
        echo ""
        echo "Checking agent status..."
        if curl -s --max-time 5 "http://$EXTERNAL_IP:$PORT/a2a" > /dev/null 2>&1; then
            echo "✅ Agent is responding early! Deployment successful."
            break
        else
            echo "Agent still starting up, continuing to wait..."
        fi
    fi
done
echo " Done!"

# Cleanup
rm "startup_script_${AGENT_ID}.sh"

echo ""
echo "🎉 NANDA Agent Deployment Complete on GCP!"
echo "=========================================="
echo "Instance Name: $INSTANCE_NAME"
echo "Zone: $ZONE"
echo "External IP: $EXTERNAL_IP"
echo "Agent URL: http://$EXTERNAL_IP:$PORT/a2a"

# Final health check
echo ""
echo "🔍 Performing final health check..."
sleep 5
if curl -s --max-time 10 -X POST "http://$EXTERNAL_IP:$PORT/a2a" \
    -H "Content-Type: application/json" \
    -d '{"content":{"text":"/ping","type":"text"},"role":"user","conversation_id":"health-check"}' | grep -q "pong"; then
    echo "✅ Agent is healthy and responding to requests!"
else
    echo "⚠️ Agent may still be starting up. Try the test commands below in a few minutes."
fi

echo ""
echo "🤖 Agent ID for A2A Communication: ${AGENT_ID}-[6-char-hex]"
echo ""
echo "📞 Use this agent in A2A messages:"
echo "   @${AGENT_ID}-[hex] your message here"
echo "   (The actual hex suffix is generated at runtime)"

echo ""
echo "🧪 Test your agent (direct communication):"
echo "curl -X POST http://$EXTERNAL_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"Hello! What can you help me with?\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test123\"}'"

echo ""
echo "🧪 Test MCP functionality:"
echo "# Smithery MCP server"
echo "curl -X POST http://$EXTERNAL_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"#smithery:fetch get some data\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"mcp-test\"}'"

echo ""
echo "# NANDA MCP server"
echo "curl -X POST http://$EXTERNAL_IP:$PORT/a2a \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"content\":{\"text\":\"#nanda:nanda-points get balance\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"nanda-test\"}'"

echo ""
echo "🔐 SSH Access:"
echo "gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE"

echo ""
echo "📋 Instance Management:"
echo "• View logs: gcloud compute instances get-serial-port-output $INSTANCE_NAME --zone=$ZONE"
echo "• Stop instance: gcloud compute instances stop $INSTANCE_NAME --zone=$ZONE"
echo "• Start instance: gcloud compute instances start $INSTANCE_NAME --zone=$ZONE"
echo "• Delete instance: gcloud compute instances delete $INSTANCE_NAME --zone=$ZONE"