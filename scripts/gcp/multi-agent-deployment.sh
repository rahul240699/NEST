#!/bin/bash

# GCP Compute Engine Multi-Agent Deployment Script
# This script creates a GCP Compute Engine instance and deploys multiple NANDA agents
# Usage: bash multi-agent-deployment.sh <ANTHROPIC_API_KEY> <AGENT_CONFIG_JSON> <SMITHERY_API_KEY> [REGISTRY_URL] [MCP_REGISTRY_URL] [ZONE] [MACHINE_TYPE]

set -e

# Function to validate port is in allowed ranges
validate_port() {
    local port=$1
    
    # Define allowed port ranges (must match firewall rules)
    local allowed_ranges=(
        "6000:6100"
        "7000:7100" 
        "8000:8100"
        "9000:9100"
        "10000:10100"
        "11000:11100"
        "12000:12100"
        "13000:13100"
        "14000:14100"
        "15000:15100"
    )
    
    for range in "${allowed_ranges[@]}"; do
        local start=${range%:*}
        local end=${range#*:}
        
        if [ "$port" -ge "$start" ] && [ "$port" -le "$end" ]; then
            return 0  # Port is valid
        fi
    done
    
    echo "❌ Port $port is not in allowed ranges. Allowed ranges:"
    for range in "${allowed_ranges[@]}"; do
        echo "   - ${range%:*}-${range#*:}"
    done
    return 1  # Port is invalid
}

# Parse arguments
ANTHROPIC_API_KEY="$1"
AGENT_CONFIG_JSON="$2" 
SMITHERY_API_KEY="$3"
REGISTRY_URL="${4:-http://registry.chat39.com:6900}"
MCP_REGISTRY_URL="${5:-}"
ZONE="${6:-us-central1-a}"
MACHINE_TYPE="${7:-e2-standard-4}"  # Larger instance for multiple agents

# Validation
if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$AGENT_CONFIG_JSON" ] || [ -z "$SMITHERY_API_KEY" ]; then
    echo "❌ Usage: $0 <ANTHROPIC_API_KEY> <AGENT_CONFIG_JSON> <SMITHERY_API_KEY> [REGISTRY_URL] [MCP_REGISTRY_URL] [ZONE] [MACHINE_TYPE]"
    echo ""
    echo "Example:"
    echo "  $0 sk-ant-xxxxx scripts/agent_configs/group-01-business-and-finance-experts.json smithery-key-xxxxx \"http://registry.chat39.com:6900\" \"https://mcp-registry.ngrok.app\" us-central1-a e2-standard-4"
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
if [ "$AGENT_COUNT" -gt 5 ] && [ "$MACHINE_TYPE" = "e2-small" ]; then
    echo "⚠️  WARNING: e2-small may be insufficient for $AGENT_COUNT agents. Consider e2-standard-4 or larger."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Validate port uniqueness and allowed ranges
echo "Validating port configuration..."

# Validate port uniqueness
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

# Validate all ports are in allowed ranges
echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
invalid_ports = []
for agent in agents:
    port = agent['port']
    # Check if port is in allowed ranges
    allowed_ranges = [
        (6000, 6100), (7000, 7100), (8000, 8100), (9000, 9100), (10000, 10100),
        (11000, 11100), (12000, 12100), (13000, 13100), (14000, 14100), (15000, 15100)
    ]
    if not any(start <= port <= end for start, end in allowed_ranges):
        invalid_ports.append(f'{agent[\"agent_id\"]}:{port}')

if invalid_ports:
    print('❌ Invalid ports found:')
    for item in invalid_ports:
        print(f'   - {item}')
    print('Allowed port ranges: 6000-6100, 7000-7100, 8000-8100, 9000-9100, 10000-10100, 11000-11100, 12000-12100, 13000-13100, 14000-14100, 15000-15100')
    sys.exit(1)
else:
    print('✅ All ports are in allowed ranges')
"

if [ $? -eq 1 ]; then
    exit 1
fi

# Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
FIREWALL_RULE_NAME="nanda-multi-agents-rule"
NETWORK_TAG="nanda-multi-agents"
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)

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
    echo "Creating firewall rule for NANDA multi-agents..."
    
    # Get agent ports for firewall rule
    AGENT_PORTS=$(echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
ports = [str(agent['port']) for agent in agents]
print(','.join(['tcp:' + port for port in ports]))
")
    
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules="tcp:22,$AGENT_PORTS" \
        --source-ranges=0.0.0.0/0 \
        --target-tags="$NETWORK_TAG" \
        --description="Firewall rule for NANDA multi-agents"
else
    echo "Firewall rule already exists"
fi

echo "✅ Firewall rule: $FIREWALL_RULE_NAME"

# Setup SSH key
echo "[3/6] Setting up SSH access..."
SSH_KEY_FILE="$HOME/.ssh/gcp_nanda_multi_key"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Creating SSH key pair..."
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_FILE" -N "" -C "nanda-gcp-multi-key"
    
    # Add public key to GCP project metadata
    gcloud compute project-info add-metadata \
        --metadata-from-file ssh-keys=<(gcloud compute project-info describe \
        --format="value(commonInstanceMetadata.items[key=ssh-keys].value)" && \
        echo "ubuntu:$(cat ${SSH_KEY_FILE}.pub)")
fi
echo "✅ SSH key configured"

# Create startup script
echo "[4/6] Creating startup script..."
cat > "startup_script_multi_${DEPLOYMENT_ID}.sh" << 'STARTUP_EOF'
#!/bin/bash
exec > /var/log/startup-script.log 2>&1

echo "=== GCP Multi-Agent Setup Started: DEPLOYMENT_ID_PLACEHOLDER ==="
date

# Update system and install dependencies (optimized for speed)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq -y
apt-get install -qq -y --no-install-recommends python3 python3-venv python3-pip git curl supervisor

# Setup project
cd /home/ubuntu
sudo -u ubuntu git clone https://github.com/projnanda/NEST.git nanda-multi-agents
cd nanda-multi-agents

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

sudo -u ubuntu python3 -m venv env
sudo -u ubuntu bash -c "source env/bin/activate && pip install --upgrade pip && pip install -e . && pip install anthropic"

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

# Save agent configuration
cat > /tmp/agents_config.json << 'AGENTS_EOF'
AGENTS_JSON_PLACEHOLDER
AGENTS_EOF

# Create supervisor configuration for each agent
echo "Creating supervisor configurations..."
mkdir -p /etc/supervisor/conf.d

while IFS= read -r agent_config; do
    AGENT_ID=$(echo "$agent_config" | jq -r '.agent_id')
    AGENT_NAME=$(echo "$agent_config" | jq -r '.agent_name')
    DOMAIN=$(echo "$agent_config" | jq -r '.domain')
    SPECIALIZATION=$(echo "$agent_config" | jq -r '.specialization')
    DESCRIPTION=$(echo "$agent_config" | jq -r '.description')
    CAPABILITIES=$(echo "$agent_config" | jq -r '.capabilities')
    PORT=$(echo "$agent_config" | jq -r '.port')
    
    echo "Configuring supervisor for agent: $AGENT_ID"
    
    # Create supervisor configuration file
    cat > "/etc/supervisor/conf.d/agent_$AGENT_ID.conf" << SUPERVISOR_EOF
[program:agent_$AGENT_ID]
command=/home/ubuntu/nanda-multi-agents/env/bin/python examples/nanda_agent.py
directory=/home/ubuntu/nanda-multi-agents
user=ubuntu
autostart=true
autorestart=true
startretries=3
stderr_logfile=/var/log/agent_$AGENT_ID.err.log
stdout_logfile=/var/log/agent_$AGENT_ID.out.log
environment=
    ANTHROPIC_API_KEY="ANTHROPIC_API_KEY_PLACEHOLDER",
    SMITHERY_API_KEY="SMITHERY_API_KEY_PLACEHOLDER",
    AGENT_ID="$AGENT_ID",
    AGENT_NAME="$AGENT_NAME",
    AGENT_DOMAIN="$DOMAIN",
    AGENT_SPECIALIZATION="$SPECIALIZATION",
    AGENT_DESCRIPTION="$DESCRIPTION",
    AGENT_CAPABILITIES="$CAPABILITIES",
    REGISTRY_URL="REGISTRY_URL_PLACEHOLDER",
    MCP_REGISTRY_URL="MCP_REGISTRY_URL_PLACEHOLDER",
    PUBLIC_URL="http://$EXTERNAL_IP:$PORT",
    PORT="$PORT"

SUPERVISOR_EOF

    echo "✅ Supervisor config created for agent $AGENT_ID on port $PORT"
    
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

echo "=== Multi-Agent Setup Complete: DEPLOYMENT_ID_PLACEHOLDER ==="
echo "All agents managed by supervisor on: $EXTERNAL_IP"
STARTUP_EOF

# Replace placeholders in startup script
sed -i '' "s/DEPLOYMENT_ID_PLACEHOLDER/$DEPLOYMENT_ID/g" "startup_script_multi_${DEPLOYMENT_ID}.sh"
sed -i '' "s/ANTHROPIC_API_KEY_PLACEHOLDER/$ANTHROPIC_API_KEY/g" "startup_script_multi_${DEPLOYMENT_ID}.sh"
sed -i '' "s/SMITHERY_API_KEY_PLACEHOLDER/$SMITHERY_API_KEY/g" "startup_script_multi_${DEPLOYMENT_ID}.sh"
sed -i '' "s|REGISTRY_URL_PLACEHOLDER|$REGISTRY_URL|g" "startup_script_multi_${DEPLOYMENT_ID}.sh"
sed -i '' "s|MCP_REGISTRY_URL_PLACEHOLDER|$MCP_REGISTRY_URL|g" "startup_script_multi_${DEPLOYMENT_ID}.sh"

# Escape JSON for sed
# Create a separate JSON file and modify the startup script to use it
echo "$AGENTS_JSON" > "agents_config_${DEPLOYMENT_ID}.json"
# Replace the heredoc with a simple cat command
sed -i '' '/AGENTS_JSON_PLACEHOLDER/r agents_config_'"${DEPLOYMENT_ID}"'.json' "startup_script_multi_${DEPLOYMENT_ID}.sh"
sed -i '' '/AGENTS_JSON_PLACEHOLDER/d' "startup_script_multi_${DEPLOYMENT_ID}.sh"

# Launch Compute Engine instance
echo "[5/6] Launching Compute Engine instance..."
INSTANCE_NAME="nanda-multi-agents-$DEPLOYMENT_ID"

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
    --labels=project=nanda,type=multi-agent,deployment-id="$DEPLOYMENT_ID" \
    --reservation-affinity=any \
    --metadata-from-file startup-script="startup_script_multi_${DEPLOYMENT_ID}.sh"

echo "✅ Instance launched: $INSTANCE_NAME"

# Wait for instance to be running
echo "[6/6] Waiting for instance and deployment..."
echo "Waiting for instance to be in RUNNING state..."
while [[ $(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)") != "RUNNING" ]]; do
    echo "Instance status: $(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(status)")"
    sleep 10
done

EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

echo "Waiting for multi-agent deployment (5 minutes for proper startup)..."
sleep 300

# Cleanup
rm "startup_script_multi_${DEPLOYMENT_ID}.sh"

# Health check all agents
echo ""
echo "🔍 Performing health checks..."
echo "$AGENTS_JSON" | python3 -c "
import json, sys, requests, time
agents = json.load(sys.stdin)
for agent in agents:
    url = f'http://$EXTERNAL_IP:{agent[\"port\"]}/health'
    try:
        response = requests.get(url, timeout=5)
        if response.status_code == 200:
            print(f'✅ {agent[\"agent_id\"]}: Healthy')
        else:
            print(f'⚠️  {agent[\"agent_id\"]}: HTTP {response.status_code}')
    except Exception as e:
        print(f'❌ {agent[\"agent_id\"]}: {str(e)}')
" 2>/dev/null || echo "Health check skipped (requests not available)"

echo ""
echo "🎉 GCP Multi-Agent Deployment Complete!"
echo "======================================"
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Instance Name: $INSTANCE_NAME"
echo "Zone: $ZONE"
echo "External IP: $EXTERNAL_IP"

# Display agent URLs
echo ""
echo "🤖 Agent URLs:"
echo "$AGENTS_JSON" | python3 -c "
import json, sys
agents = json.load(sys.stdin)
for agent in agents:
    print(f\"  {agent['agent_id']}: http://$EXTERNAL_IP:{agent['port']}/a2a\")
"

# Get actual agent IDs with hex suffixes from logs
echo "Getting actual agent IDs (with hex suffixes)..."
ACTUAL_AGENT_IDS=""
sleep 10
for attempt in {1..3}; do
    ACTUAL_AGENT_IDS=$(gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE --command="grep 'Generated agent_id:' /var/log/agent_*.out.log 2>/dev/null | cut -d':' -f3 | tr -d ' '" 2>/dev/null || echo "")
    if [ -n "$ACTUAL_AGENT_IDS" ]; then
        break
    fi
    echo "Attempt $attempt: Waiting for agent logs..."
    sleep 5
done

if [ -n "$ACTUAL_AGENT_IDS" ]; then
    echo ""
    echo "🤖 Actual Agent IDs for A2A Communication:"
    echo "$ACTUAL_AGENT_IDS" | while read -r agent_id; do
        if [ -n "$agent_id" ]; then
            echo "  @$agent_id"
        fi
    done
    echo ""
    echo "📞 Use these in A2A messages:"
    echo "  Example: @[agent-id] your message here"
else
    echo ""
    echo "⚠️  Could not retrieve actual agent IDs from logs."
    echo "📞 Agent IDs will be: [base-id]-[6-char-hex]"
fi

echo ""
echo "📊 Monitor agents:"
echo "gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE --command='sudo supervisorctl status'"

echo ""
echo "🔄 Restart all agents:"
echo "gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE --command='sudo supervisorctl restart all'"

echo ""
echo "📋 Instance Management:"
echo "• View logs: gcloud compute instances get-serial-port-output $INSTANCE_NAME --zone=$ZONE"
echo "• SSH access: gcloud compute ssh ubuntu@$INSTANCE_NAME --zone=$ZONE"
echo "• Stop instance: gcloud compute instances stop $INSTANCE_NAME --zone=$ZONE"
echo "• Start instance: gcloud compute instances start $INSTANCE_NAME --zone=$ZONE"
echo "• Delete instance: gcloud compute instances delete $INSTANCE_NAME --zone=$ZONE"