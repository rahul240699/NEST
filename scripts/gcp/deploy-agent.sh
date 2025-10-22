#!/bin/bash

# Simple GCP NANDA Agent Deployment Script
# Usage: bash deploy-agent.sh <AGENT_TYPE> <AGENT_ID> <ANTHROPIC_API_KEY> [PORT] [REGISTRY_URL] [ZONE] [MACHINE_TYPE]

set -e

AGENT_TYPE=$1
AGENT_ID=$2
ANTHROPIC_API_KEY=$3
PORT=${4:-6000}
REGISTRY_URL=${5:-""}
ZONE=${6:-us-central1-a}
MACHINE_TYPE=${7:-e2-micro}

if [ -z "$AGENT_TYPE" ] || [ -z "$AGENT_ID" ] || [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "🤖 Simple GCP NANDA Agent Deployment"
  echo "===================================="
  echo ""
  echo "Usage: bash deploy-agent.sh <AGENT_TYPE> <AGENT_ID> <ANTHROPIC_API_KEY> [PORT] [REGISTRY_URL] [ZONE] [MACHINE_TYPE]"
  echo ""
  echo "Agent Types:"
  echo "  • helpful    - General helpful agent"
  echo "  • pirate     - Pirate personality agent"
  echo "  • echo       - Simple echo agent"
  echo "  • analyst    - LangChain document analyst (requires LangChain)"
  echo ""
  echo "Examples:"
  echo "  bash deploy-agent.sh helpful my_gcp_agent sk-ant-xxxxx"
  echo "  bash deploy-agent.sh analyst doc_analyzer sk-ant-xxxxx 6020"
  echo "  bash deploy-agent.sh pirate captain_jack sk-ant-xxxxx 6000 https://registry.example.com us-central1-a e2-small"
  echo ""
  exit 1
fi

echo "🚀 Deploying NANDA Agent on GCP"
echo "================================"
echo "Agent Type: $AGENT_TYPE"
echo "Agent ID: $AGENT_ID"
echo "Port: $PORT"
echo "Zone: $ZONE"
echo "Machine Type: $MACHINE_TYPE"
echo "Registry: ${REGISTRY_URL:-"None (local only)"}"
echo ""

# Check GCP configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "❌ GCP project not configured. Run 'gcloud config set project YOUR_PROJECT_ID' first."
    exit 1
fi

echo "Using GCP project: $PROJECT_ID"
echo ""

echo "[1/4] Setting up GCP firewall rule..."
FIREWALL_RULE_NAME="nanda-simple-agents"
NETWORK_TAG="nanda-simple"

if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" >/dev/null 2>&1; then
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:22,tcp:6000-6100 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="$NETWORK_TAG" \
        --description="Firewall rule for simple NANDA agents"
fi

echo "[2/4] Creating startup script..."
cat > startup_script_${AGENT_ID}.sh << EOF
#!/bin/bash
exec > /var/log/startup-script.log 2>&1

echo "=== NANDA Agent Setup Started on GCP: $AGENT_ID ==="
date

# Update system and install dependencies
apt-get update -y
apt-get install -y python3 python3-pip python3-venv git curl

# Setup project as ubuntu user
cd /home/ubuntu
PROJECT_DIR="nanda-agent-$AGENT_ID"

# Remove existing directory if it exists
if [ -d "\$PROJECT_DIR" ]; then
    rm -rf "\$PROJECT_DIR"
fi

# Clone streamlined adapter
sudo -u ubuntu git clone https://github.com/projnanda/NEST.git "\$PROJECT_DIR"
cd "\$PROJECT_DIR"

# Create virtual environment and install
sudo -u ubuntu python3 -m venv env
sudo -u ubuntu bash -c "source env/bin/activate && pip install --upgrade pip && pip install anthropic python-a2a requests"

# Install agent-specific dependencies
case "$AGENT_TYPE" in
    "analyst")
        echo "Installing LangChain dependencies for analyst agent..."
        sudo -u ubuntu bash -c "source env/bin/activate && pip install langchain-core langchain-anthropic"
        ;;
    "helpful"|"pirate"|"echo")
        echo "Using built-in agent type (no extra dependencies)"
        ;;
    *)
        echo "⚠️ Unknown agent type: $AGENT_TYPE. Proceeding with basic installation..."
        ;;
esac

# Get external IP from GCP metadata
echo "Getting external IP address from GCP metadata..."
for attempt in {1..5}; do
    EXTERNAL_IP=\$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    if [ -n "\$EXTERNAL_IP" ] && [[ \$EXTERNAL_IP =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$ ]]; then
        echo "Retrieved external IP: \$EXTERNAL_IP"
        break
    fi
    echo "Attempt \$attempt failed, retrying..."
    sleep 3
done

if [ -z "\$EXTERNAL_IP" ]; then
    echo "ERROR: Could not retrieve external IP"
    exit 1
fi

# Create agent startup script
sudo -u ubuntu cat > run_agent.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Auto-generated NANDA Agent for GCP
Agent Type: $AGENT_TYPE
Agent ID: $AGENT_ID
Port: $PORT
"""

import os
import sys

# Set API key
os.environ["ANTHROPIC_API_KEY"] = "$ANTHROPIC_API_KEY"

# Add project to path
sys.path.append(os.path.dirname(__file__))

from nanda_core.core.adapter import NANDA, helpful_agent, pirate_agent, echo_agent

def main():
    print("🤖 Starting NANDA Agent on GCP: $AGENT_ID")
    print("Agent Type: $AGENT_TYPE")
    print("Port: $PORT")
    print("")
    
    # Select agent logic based on type
    agent_logic = helpful_agent  # default
    
    if "$AGENT_TYPE" == "pirate":
        agent_logic = pirate_agent
    elif "$AGENT_TYPE" == "echo":
        agent_logic = echo_agent
    elif "$AGENT_TYPE" == "analyst":
        try:
            from examples.langchain_analyst_agent import DocumentAnalyst, create_analyst_agent_logic
            analyst = DocumentAnalyst()
            agent_logic = create_analyst_agent_logic(analyst)
            print("📊 LangChain Document Analyst loaded")
        except ImportError:
            print("⚠️ LangChain dependencies not available, using helpful agent")
            agent_logic = helpful_agent
    
    # Create NANDA agent
    nanda = NANDA(
        agent_id="$AGENT_ID",
        agent_logic=agent_logic,
        port=$PORT,
        registry_url="${REGISTRY_URL}" if "${REGISTRY_URL}" else None,
        public_url="http://\$EXTERNAL_IP:$PORT" if "${REGISTRY_URL}" else None
    )
    
    print("🚀 Agent ready on GCP! Send messages to http://\$EXTERNAL_IP:$PORT/a2a")
    if "${REGISTRY_URL}":
        print("🌐 Will attempt to register with registry: ${REGISTRY_URL}")
    
    try:
        nanda.start(register=bool("${REGISTRY_URL}"))
    except KeyboardInterrupt:
        print("\\n🛑 Agent stopped")

if __name__ == "__main__":
    main()
PYTHON_EOF

sudo -u ubuntu chmod +x run_agent.py

# Start agent in background with proper environment
echo "Starting NANDA agent..."
sudo -u ubuntu bash -c "
    cd /home/ubuntu/nanda-agent-$AGENT_ID
    source env/bin/activate
    nohup python3 run_agent.py > agent.log 2>&1 &
"

sleep 5

echo "=== NANDA Agent Setup Complete on GCP: $AGENT_ID ==="
echo "Agent URL: http://\$EXTERNAL_IP:$PORT/a2a"
echo "External IP: \$EXTERNAL_IP"
EOF

echo "[3/4] Launching GCP Compute Engine instance..."
INSTANCE_NAME="nanda-simple-$AGENT_ID"

gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --network-interface=network-tier=PREMIUM,subnet=default \
    --maintenance-policy=MIGRATE \
    --provisioning-model=STANDARD \
    --service-account="$(gcloud iam service-accounts list --filter="displayName:Compute Engine default service account" --format="value(email)" 2>/dev/null || echo "")" \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write \
    --tags="$NETWORK_TAG" \
    --create-disk=auto-delete=yes,boot=yes,device-name="$INSTANCE_NAME",image=projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20241002,mode=rw,size=20,type=projects/$PROJECT_ID/zones/$ZONE/diskTypes/pd-balanced \
    --labels=project=nanda,type=simple-agent \
    --metadata-from-file startup-script=startup_script_${AGENT_ID}.sh

echo "✅ Instance launched: $INSTANCE_NAME"

# Wait for instance to be running
echo "[4/4] Waiting for instance and agent startup..."
while [[ $(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)" 2>/dev/null) != "RUNNING" ]]; do
    sleep 5
done

EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

echo "Waiting for agent deployment (2 minutes)..."
sleep 120

# Cleanup
rm startup_script_${AGENT_ID}.sh

echo ""
echo "🎉 GCP NANDA Agent Deployment Complete!"
echo "======================================"
echo "Agent ID: $AGENT_ID"
echo "Type: $AGENT_TYPE"
echo "Instance: $INSTANCE_NAME"
echo "Zone: $ZONE"
echo "External IP: $EXTERNAL_IP"
echo "Port: $PORT"
echo ""

# Test agent connectivity
echo "🔍 Testing agent connectivity..."
if curl -f -s "http://$EXTERNAL_IP:$PORT/health" >/dev/null 2>&1; then
    echo "✅ Agent is responding on http://$EXTERNAL_IP:$PORT"
else
    echo "⚠️  Agent may still be starting up. Check logs if needed."
fi

echo ""
echo "📋 Useful commands:"
echo "  • SSH: gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE"
echo "  • Logs: gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE --command='tail -f nanda-agent-$AGENT_ID/agent.log'"
echo "  • Stop: gcloud compute instances stop $INSTANCE_NAME --zone=$ZONE"
echo "  • Delete: gcloud compute instances delete $INSTANCE_NAME --zone=$ZONE"
echo ""
echo "🔗 Agent URL: http://$EXTERNAL_IP:$PORT/a2a"
echo ""
echo "🧪 Test agent:"
echo "curl -X POST http://$EXTERNAL_IP:$PORT/a2a -H 'Content-Type: application/json' -d '{\"content\":{\"text\":\"hello\",\"type\":\"text\"},\"role\":\"user\",\"conversation_id\":\"test\"}'"