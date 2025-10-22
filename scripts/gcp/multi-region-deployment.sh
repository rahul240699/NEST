#!/bin/bash

# Multi-Region Multi-Agent Deployment Script
# This script deploys agents across multiple GCP regions for better distributed architecture
# Usage: bash multi-region-deployment.sh <ANTHROPIC_API_KEY> <SMITHERY_API_KEY> <REGISTRY_URL> <MCP_REGISTRY_URL>

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
SMITHERY_API_KEY="$2"
REGISTRY_URL="${3:-http://registry.chat39.com:6900}"
MCP_REGISTRY_URL="${4:-http://nanda-registry.chat39.com:5000}"

# Validation
if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$SMITHERY_API_KEY" ]; then
    echo "❌ Usage: $0 <ANTHROPIC_API_KEY> <SMITHERY_API_KEY> [REGISTRY_URL] [MCP_REGISTRY_URL]"
    echo ""
    echo "Example:"
    echo "  $0 sk-ant-xxxxx smithery-key-xxxxx \"http://registry.chat39.com:6900\" \"https://mcp-registry.ngrok.app\""
    exit 1
fi

echo "🌍 GCP Multi-Region Multi-Agent Deployment"
echo "=========================================="

# Validate all agent configurations have allowed ports
echo "🔍 Validating all agent configurations..."
for REGION in "${!REGION_DEPLOYMENTS[@]}"; do
    AGENT_CONFIG="${REGION_DEPLOYMENTS[$REGION]}"
    
    if [ -f "$AGENT_CONFIG" ]; then
        echo "   Validating $AGENT_CONFIG..."
        AGENTS_JSON=$(cat "$AGENT_CONFIG")
        
        # Validate all ports are in allowed ranges
        python3 -c "
import json
agents = json.loads('$AGENTS_JSON')
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
    print('❌ Invalid ports found in $AGENT_CONFIG:')
    for item in invalid_ports:
        print(f'   - {item}')
    exit(1)
else:
    print('✅ All ports valid for $AGENT_CONFIG')
        " || exit 1
    else
        echo "❌ Agent config file not found: $AGENT_CONFIG"
        exit 1
    fi
done

echo ""

# Define regions and agent groups for distribution
declare -A REGION_DEPLOYMENTS=(
    ["us-central1-a"]="../agent_configs/group-01-business-and-finance-experts.json"
    ["us-east1-b"]="../agent_configs/group-02-technology-and-engineering.json"
    ["us-west1-b"]="../agent_configs/group-03-creative-and-design.json"
)

DEPLOYMENT_ID="multi-region-$(date +%Y%m%d-%H%M%S)"
echo "Deployment ID: $DEPLOYMENT_ID"
echo ""

# Deploy to each region
for REGION in "${!REGION_DEPLOYMENTS[@]}"; do
    AGENT_CONFIG="${REGION_DEPLOYMENTS[$REGION]}"
    
    echo "🚀 Deploying to region: $REGION"
    echo "   Agent config: $AGENT_CONFIG"
    echo "   Starting deployment..."
    
    # Run multi-agent deployment for this region
    bash ./multi-agent-deployment.sh \
        "$ANTHROPIC_API_KEY" \
        "$AGENT_CONFIG" \
        "$SMITHERY_API_KEY" \
        "$REGISTRY_URL" \
        "$MCP_REGISTRY_URL" \
        "$REGION" \
        "e2-standard-4" &
    
    echo "   Deployment started in background for $REGION"
    echo ""
    
    # Add a delay to avoid overwhelming the API
    sleep 30
done

echo "⏳ Waiting for all regional deployments to complete..."
wait

echo ""
echo "🎉 Multi-Region Deployment Complete!"
echo "====================================="
echo "Deployment ID: $DEPLOYMENT_ID"
echo ""

# Get all deployed instances across regions
echo "📍 Deployed Instances:"
for REGION in "${!REGION_DEPLOYMENTS[@]}"; do
    echo "Region: $REGION"
    gcloud compute instances list --filter="zone:$REGION AND name~nanda-multi-agents" --format="table(name,zone,machineType,status,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)" || echo "   No instances found in $REGION"
    echo ""
done

echo "🔗 Cross-Region A2A Communication Test:"
echo "All agents across regions can communicate with each other using the format:"
echo "  @[agent-id] your message here"
echo ""
echo "Example cross-region communication:"
echo '  curl -X POST http://[region1-ip]:[port]/a2a \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"content":{"text":"@[agent-in-region2] Hello from region 1!","type":"text"},"role":"user","conversation_id":"cross-region-test"}'"'"
echo ""

echo "📊 Management Commands:"
echo "# List all instances across regions"
echo "gcloud compute instances list --filter='name~nanda-multi-agents' --format='table(name,zone,status,networkInterfaces[0].accessConfigs[0].natIP)'"
echo ""
echo "# Delete all multi-region instances"
echo "gcloud compute instances list --filter='name~nanda-multi-agents' --format='value(name,zone)' | while read name zone; do gcloud compute instances delete \$name --zone=\$zone --quiet; done"