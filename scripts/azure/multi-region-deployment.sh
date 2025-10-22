#!/bin/bash

# Azure Multi-Region Deployment Script
# Deploys agent groups across multiple Azure regions

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
ANTHROPIC_API_KEY="$1"
REGIONS_CONFIG="$2"  # JSON array: [{"region":"eastus","config":"group-01.json"}, ...]
AGENT_REGISTRY_URL="${3:-http://registry.chat39.com:6900}"
MCP_REGISTRY_URL="${4:-}"
VM_SIZE="${5:-Standard_B4ms}"

# Validation
if [ -z "$ANTHROPIC_API_KEY" ] || [ -z "$REGIONS_CONFIG" ]; then
    echo -e "${RED}❌ Usage: $0 <ANTHROPIC_API_KEY> <REGIONS_CONFIG> [AGENT_REGISTRY_URL] [MCP_REGISTRY_URL] [VM_SIZE]${NC}"
    echo ""
    echo "Example:"
    echo "  $0 sk-ant-xxx '[{\"region\":\"eastus\",\"config\":\"group-01.json\"},{\"region\":\"westus\",\"config\":\"group-02.json\"}]'"
    exit 1
fi

# Parse regions config
if [ -f "$REGIONS_CONFIG" ]; then
    REGIONS_JSON=$(cat "$REGIONS_CONFIG")
else
    REGIONS_JSON="$REGIONS_CONFIG"
fi

REGION_COUNT=$(echo "$REGIONS_JSON" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))")

echo -e "${GREEN}🌍 Starting Azure Multi-Region Deployment${NC}"
echo "Regions to deploy: $REGION_COUNT"
echo ""

# Deployment tracking
DEPLOYMENT_LOG="azure-multi-region-deployment-$(date +%Y%m%d-%H%M%S).log"
DEPLOYMENTS=()

# Deploy to each region
REGION_INDEX=1
echo "$REGIONS_JSON" | python3 -c "
import json, sys
regions = json.load(sys.stdin)
for region in regions:
    print(f\"{region['region']}|{region['config']}\")
" | while IFS='|' read -r REGION AGENT_CONFIG; do
    echo -e "${YELLOW}[$REGION_INDEX/$REGION_COUNT] Deploying to region: $REGION${NC}"
    echo "Agent config: $AGENT_CONFIG"
    
    # Run multi-agent deployment for this region
    bash "$(dirname "$0")/multi-agent-deployment.sh" \
        "$ANTHROPIC_API_KEY" \
        "$AGENT_CONFIG" \
        "$AGENT_REGISTRY_URL" \
        "$MCP_REGISTRY_URL" \
        "$REGION" \
        "$VM_SIZE" \
        2>&1 | tee -a "$DEPLOYMENT_LOG"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}✅ Successfully deployed to $REGION${NC}"
        DEPLOYMENTS+=("$REGION:SUCCESS")
    else
        echo -e "${RED}❌ Failed to deploy to $REGION${NC}"
        DEPLOYMENTS+=("$REGION:FAILED")
    fi
    
    echo ""
    REGION_INDEX=$((REGION_INDEX + 1))
done

# Summary
echo ""
echo -e "${GREEN}🎉 Multi-Region Deployment Complete!${NC}"
echo "======================================"
echo ""
echo "📊 Deployment Summary:"
for deployment in "${DEPLOYMENTS[@]}"; do
    IFS=':' read -r region status <<< "$deployment"
    if [ "$status" = "SUCCESS" ]; then
        echo -e "  ${GREEN}✅ $region${NC}"
    else
        echo -e "  ${RED}❌ $region${NC}"
    fi
done

echo ""
echo "📋 Full deployment log: $DEPLOYMENT_LOG"
echo ""
echo "🔍 View all VMs:"
echo "  az vm list --resource-group nanda-agents-rg --output table"
echo ""
echo "🗑️  Delete all deployments:"
echo "  az group delete --name nanda-agents-rg --yes"
