# Azure Deployment Scripts for NANDA Agents

This directory contains scripts for deploying NANDA agents on Microsoft Azure.

## Prerequisites

### 1. Install Azure CLI

**macOS:**
```bash
brew install azure-cli
```

**Linux:**
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

**Windows:**
Download from: https://aka.ms/installazurecliwindows

### 2. Login to Azure

```bash
az login
```

### 3. Set Default Subscription (if you have multiple)

```bash
# List subscriptions
az account list --output table

# Set default
az account set --subscription "YOUR_SUBSCRIPTION_ID"
```

## Scripts Overview

### 1. `single-agent-deployment.sh`
Deploy a single NANDA agent on an Azure VM.

**Usage:**
```bash
bash single-agent-deployment.sh \
  <AGENT_ID> \
  <ANTHROPIC_API_KEY> \
  <AGENT_NAME> \
  [GIT_BRANCH] \
  [SPECIALIZATION] \
  [CAPABILITIES] \
  [SMITHERY_API_KEY] \
  [AGENT_REGISTRY_URL] \
  [MCP_REGISTRY_URL] \
  [PORT] \
  [LOCATION] \
  [VM_SIZE]
```

**Example:**
```bash
bash single-agent-deployment.sh \
  "test-agent" \
  "sk-ant-api03-..." \
  "Test Agent" \
  "main" \
  "general assistant" \
  "help,conversation" \
  "" \
  "http://registry.chat39.com:6900" \
  "" \
  6050 \
  eastus \
  Standard_B2s
```

**Parameters:**
- `AGENT_ID`: Unique identifier for the agent
- `ANTHROPIC_API_KEY`: Your Anthropic API key for Claude
- `AGENT_NAME`: Display name for the agent
- `GIT_BRANCH`: Git branch to deploy (default: main)
- `SPECIALIZATION`: Agent's area of expertise
- `CAPABILITIES`: Comma-separated capabilities
- `SMITHERY_API_KEY`: Optional Smithery API key for MCP
- `AGENT_REGISTRY_URL`: URL for agent registry
- `MCP_REGISTRY_URL`: URL for MCP registry
- `PORT`: Port number (must be in allowed ranges)
- `LOCATION`: Azure region (default: eastus)
- `VM_SIZE`: VM size (default: Standard_B2s)

**Common Azure Regions:**
- `eastus` - East US
- `westus` - West US
- `centralus` - Central US
- `westeurope` - West Europe
- `northeurope` - North Europe
- `southeastasia` - Southeast Asia
- `eastasia` - East Asia

**Common VM Sizes:**
- `Standard_B1s` - 1 vCPU, 1 GB RAM (basic, low cost)
- `Standard_B2s` - 2 vCPUs, 4 GB RAM (recommended for single agent)
- `Standard_B4ms` - 4 vCPUs, 16 GB RAM (for multi-agent)
- `Standard_D2s_v3` - 2 vCPUs, 8 GB RAM (production single agent)
- `Standard_D4s_v3` - 4 vCPUs, 16 GB RAM (production multi-agent)

### 2. `multi-agent-deployment.sh`
Deploy multiple NANDA agents on a single Azure VM using supervisor.

**Usage:**
```bash
bash multi-agent-deployment.sh \
  <ANTHROPIC_API_KEY> \
  <AGENT_CONFIG_JSON> \
  [AGENT_REGISTRY_URL] \
  [MCP_REGISTRY_URL] \
  [LOCATION] \
  [VM_SIZE]
```

**Example:**
```bash
bash multi-agent-deployment.sh \
  "sk-ant-api03-..." \
  "../agent_configs/group-01-business-and-finance-experts.json" \
  "http://registry.chat39.com:6900" \
  "" \
  eastus \
  Standard_B4ms
```

**Parameters:**
- `ANTHROPIC_API_KEY`: Your Anthropic API key
- `AGENT_CONFIG_JSON`: Path to agent configuration JSON or JSON string
- `AGENT_REGISTRY_URL`: URL for agent registry
- `MCP_REGISTRY_URL`: URL for MCP registry
- `LOCATION`: Azure region
- `VM_SIZE`: VM size (recommend Standard_B4ms or larger for multiple agents)

### 3. `multi-region-deployment.sh`
Deploy agent groups across multiple Azure regions.

**Usage:**
```bash
bash multi-region-deployment.sh \
  <ANTHROPIC_API_KEY> \
  <REGIONS_CONFIG> \
  [AGENT_REGISTRY_URL] \
  [MCP_REGISTRY_URL] \
  [VM_SIZE]
```

**Example:**
```bash
bash multi-region-deployment.sh \
  "sk-ant-api03-..." \
  '[{"region":"eastus","config":"../agent_configs/group-01-business-and-finance-experts.json"},{"region":"westus","config":"../agent_configs/group-02-technology-and-engineering.json"}]' \
  "http://registry.chat39.com:6900" \
  "" \
  Standard_B4ms
```

## Agent Configuration Format

Agent configuration files should be JSON arrays with the following structure:

```json
[
  {
    "agent_id": "agent-identifier",
    "agent_name": "Agent Display Name",
    "domain": "agent domain",
    "specialization": "what the agent specializes in",
    "description": "detailed description",
    "capabilities": "capability1,capability2,capability3",
    "port": 6000
  }
]
```

**Port Requirements:**
- Ports must be in allowed ranges: 6000-6100, 7000-7100, 8000-8100, etc.
- Each agent must have a unique port
- See agent_configs directory for examples

## Monitoring & Management

### Check Agent Status
```bash
# SSH into the VM
ssh azureuser@<PUBLIC_IP>

# For single agent
sudo systemctl status nanda-agent

# For multi-agent
sudo supervisorctl status
```

### View Logs
```bash
# Single agent
ssh azureuser@<PUBLIC_IP> 'sudo journalctl -u nanda-agent -f'

# Multi-agent
ssh azureuser@<PUBLIC_IP> 'sudo tail -f /var/log/agent_*.out.log'
```

### Restart Agents
```bash
# Single agent
ssh azureuser@<PUBLIC_IP> 'sudo systemctl restart nanda-agent'

# Multi-agent
ssh azureuser@<PUBLIC_IP> 'sudo supervisorctl restart all'
```

### List All VMs
```bash
az vm list --resource-group nanda-agents-rg --output table
```

### Get VM Details
```bash
az vm show --resource-group nanda-agents-rg --name <VM_NAME>
```

## Cleanup

### Delete Single VM
```bash
az vm delete --resource-group nanda-agents-rg --name <VM_NAME> --yes
```

### Delete All Resources
```bash
az group delete --name nanda-agents-rg --yes
```

This will delete:
- All VMs
- All network interfaces
- All public IPs
- Virtual network
- Network security group

## Network Configuration

The scripts automatically create and configure:
- **Resource Group**: `nanda-agents-rg`
- **Virtual Network**: `nanda-agents-vnet` (10.0.0.0/16)
- **Subnet**: `nanda-agents-subnet` (10.0.1.0/24)
- **Network Security Group**: `nanda-agents-nsg`

**Firewall Rules:**
- SSH (22) - Open to all
- Agent ports (6000-15100 in ranges) - Open to all

## Cost Optimization

### VM Sizes by Use Case

**Development/Testing:**
- Single agent: `Standard_B1s` or `Standard_B2s`
- Multi-agent (3-5): `Standard_B2ms`
- Multi-agent (6-10): `Standard_B4ms`

**Production:**
- Single agent: `Standard_D2s_v3`
- Multi-agent (3-5): `Standard_D2s_v3`
- Multi-agent (6-10): `Standard_D4s_v3`

### Auto-shutdown
Set up auto-shutdown to save costs during off-hours:

```bash
az vm auto-shutdown \
  --resource-group nanda-agents-rg \
  --name <VM_NAME> \
  --time 1900 \
  --location eastus
```

### Spot Instances
For non-critical workloads, use spot instances to save up to 90%:

```bash
# Add to VM creation
--priority Spot \
--max-price -1 \
--eviction-policy Deallocate
```

## Troubleshooting

### VM Creation Fails
- Check subscription quotas: `az vm list-usage --location eastus --output table`
- Verify you have permissions to create VMs
- Try a different region

### Agents Not Starting
1. Check cloud-init logs:
```bash
ssh azureuser@<PUBLIC_IP> 'sudo cat /var/log/cloud-init-output.log'
```

2. Check agent service:
```bash
ssh azureuser@<PUBLIC_IP> 'sudo systemctl status nanda-agent'
```

3. Check agent logs:
```bash
ssh azureuser@<PUBLIC_IP> 'sudo journalctl -u nanda-agent -n 100'
```

### Connection Timeout
- Verify NSG rules: `az network nsg rule list --resource-group nanda-agents-rg --nsg-name nanda-agents-nsg --output table`
- Check if VM is running: `az vm get-instance-view --resource-group nanda-agents-rg --name <VM_NAME>`
- Wait 2-3 minutes after deployment for cloud-init to complete

## Security Best Practices

1. **Restrict SSH Access**: Update NSG to allow SSH only from your IP
```bash
az network nsg rule update \
  --resource-group nanda-agents-rg \
  --nsg-name nanda-agents-nsg \
  --name AllowSSH \
  --source-address-prefixes <YOUR_IP>/32
```

2. **Use SSH Keys**: Scripts automatically generate SSH keys (stored in `~/.ssh/`)

3. **Enable Disk Encryption**: Add to VM creation
```bash
--encryption-at-host true
```

4. **Use Azure Key Vault**: Store API keys in Key Vault instead of passing as parameters

## Support

For issues or questions:
- Check Azure documentation: https://docs.microsoft.com/azure/
- Review deployment logs
- Check agent logs on the VM
- Verify network connectivity

## License

Part of the NANDA Agent Framework - See LICENSE in project root
