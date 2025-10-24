# DigitalOcean Deployment Scripts for NANDA Agents

This directory contains scripts for deploying NANDA agents on DigitalOcean droplets.

## Prerequisites

1. **DigitalOcean Account**: Sign up at [digitalocean.com](https://www.digitalocean.com/)
2. **doctl CLI**: Install the DigitalOcean command-line tool
   ```bash
   # macOS
   brew install doctl
   
   # Linux
   cd ~
   wget https://github.com/digitalocean/doctl/releases/download/v1.98.1/doctl-1.98.1-linux-amd64.tar.gz
   tar xf ~/doctl-1.98.1-linux-amd64.tar.gz
   sudo mv ~/doctl /usr/local/bin
   
   # Windows
   # Download from https://github.com/digitalocean/doctl/releases
   ```

3. **Authenticate doctl**:
   ```bash
   doctl auth init
   # Enter your DigitalOcean API token when prompted
   # Generate token at: https://cloud.digitalocean.com/account/api/tokens
   ```

4. **Anthropic API Key**: Get your API key from [console.anthropic.com](https://console.anthropic.com/)

## Scripts

### 1. Single Agent Deployment

Deploy a single NANDA agent on a DigitalOcean droplet.

**Usage:**
```bash
bash scripts/digitalocean/single-agent-deployment.sh \
  <AGENT_ID> \
  <ANTHROPIC_API_KEY> \
  <AGENT_NAME> \
  <DOMAIN> \
  <SPECIALIZATION> \
  <DESCRIPTION> \
  <CAPABILITIES> \
  [REGISTRY_URL] \
  [PORT] \
  [REGION] \
  [DROPLET_SIZE]
```

**Example:**
```bash
bash scripts/digitalocean/single-agent-deployment.sh \
  "finance-analyst" \
  "sk-ant-api03-xxxxx" \
  "Finance Analyst" \
  "finance" \
  "financial analysis expert" \
  "Specializes in financial analysis, market research, and investment strategies" \
  "finance,analysis,markets,trading" \
  "http://registry.chat39.com:6900" \
  6001 \
  nyc3 \
  s-1vcpu-2gb
```

**Parameters:**
- `AGENT_ID`: Unique identifier (e.g., "finance-analyst")
- `ANTHROPIC_API_KEY`: Your Anthropic API key
- `AGENT_NAME`: Display name (e.g., "Finance Analyst")
- `DOMAIN`: Primary domain (e.g., "finance")
- `SPECIALIZATION`: Brief role description
- `DESCRIPTION`: Detailed description
- `CAPABILITIES`: Comma-separated capabilities
- `REGISTRY_URL`: Optional registry URL (default: http://registry.chat39.com:6900)
- `PORT`: Agent port (default: 6000)
- `REGION`: DigitalOcean region (default: nyc1)
- `DROPLET_SIZE`: Droplet size (default: s-1vcpu-1gb)

### 2. Multi-Agent Deployment

Deploy multiple NANDA agents on a single DigitalOcean droplet using supervisor.

**Usage:**
```bash
bash scripts/digitalocean/multi-agent-deployment.sh \
  <ANTHROPIC_API_KEY> \
  <AGENT_CONFIG_JSON> \
  [REGISTRY_URL] \
  [REGION] \
  [DROPLET_SIZE]
```

**Example:**
```bash
bash scripts/digitalocean/multi-agent-deployment.sh \
  "sk-ant-api03-xxxxx" \
  "scripts/agent_configs/test-3-agents.json" \
  "http://registry.chat39.com:6900" \
  nyc3 \
  s-2vcpu-4gb
```

**Parameters:**
- `ANTHROPIC_API_KEY`: Your Anthropic API key
- `AGENT_CONFIG_JSON`: Path to JSON config file or JSON string
- `REGISTRY_URL`: Registry URL (default: http://registry.chat39.com:6900)
- `REGION`: DigitalOcean region (default: nyc1)
- `DROPLET_SIZE`: Droplet size (default: s-2vcpu-4gb)


## DigitalOcean Regions

Common DigitalOcean regions:
- `nyc1`, `nyc3` - New York
- `sfo3` - San Francisco
- `ams3` - Amsterdam
- `sgp1` - Singapore
- `lon1` - London
- `fra1` - Frankfurt
- `tor1` - Toronto
- `blr1` - Bangalore

## Droplet Sizes

Common droplet sizes:
- `s-1vcpu-1gb` - 1 vCPU, 1GB RAM (~$6/month) - Good for 1-2 agents
- `s-1vcpu-2gb` - 1 vCPU, 2GB RAM (~$12/month) - Good for 2-3 agents
- `s-2vcpu-2gb` - 2 vCPUs, 2GB RAM (~$18/month) - Good for 3-5 agents
- `s-2vcpu-4gb` - 2 vCPUs, 4GB RAM (~$24/month) - Good for 5-10 agents
- `s-4vcpu-8gb` - 4 vCPUs, 8GB RAM (~$48/month) - Good for 10+ agents

## Testing Deployed Agents

### Single Agent Test
```bash
curl -X POST http://<PUBLIC_IP>:<PORT>/a2a \
  -H "Content-Type: application/json" \
  -d '{"content":{"text":"Hello! What can you help me with?","type":"text"},"role":"user","conversation_id":"test123"}'
```

### Multi-Agent Test
```bash
# Test each agent on its respective port
for port in 6001 6002 6003; do
  echo "Testing port $port..."
  curl -X POST http://<PUBLIC_IP>:$port/a2a \
    -H "Content-Type: application/json" \
    -d '{"content":{"text":"Hello!","type":"text"},"role":"user","conversation_id":"test"}'
  echo ""
done
```



## Cleanup

### Delete droplet:
```bash
doctl compute droplet delete <DROPLET_ID>
```

### Delete firewall:
```bash
doctl compute firewall delete <FIREWALL_ID>
```

### Delete SSH key (if no longer needed):
```bash
doctl compute ssh-key delete <SSH_KEY_ID>
```

## Features

### Single Agent Deployment
- ✅ Automated droplet creation and configuration
- ✅ Firewall setup with SSH and agent port access
- ✅ SSH key generation and management
- ✅ User data script for automatic agent setup
- ✅ Public IP retrieval via DigitalOcean metadata service
- ✅ Comprehensive deployment logging

### Multi-Agent Deployment
- ✅ Deploy multiple agents on one droplet
- ✅ Supervisor process management for all agents
- ✅ Automatic restart on failure
- ✅ Individual agent log files
- ✅ Port validation (no duplicates)
- ✅ Dynamic firewall configuration for all ports
- ✅ Health checks for all deployed agents

## Troubleshooting

### Authentication issues:
```bash
# Re-initialize doctl authentication
doctl auth init

# Verify authentication
doctl account get
```

### Droplet not accessible:
```bash
# Check droplet status
doctl compute droplet list

# Check firewall rules
doctl compute firewall list
```

### Agent not responding:
```bash
# Check if agent process is running
ssh -i <key> root@<IP> 'ps aux | grep nanda_agent'

# Check agent logs
ssh -i <key> root@<IP> 'tail -100 /root/nanda-agent-*/agent.log'
```

### Multi-agent supervisor issues:
```bash
# Check supervisor status
ssh -i nanda-multi-agent-key root@<IP> 'supervisorctl status'

# Check supervisor logs
ssh -i nanda-multi-agent-key root@<IP> 'tail -100 /var/log/supervisor/supervisord.log'

# Manually restart supervisor
ssh -i nanda-multi-agent-key root@<IP> 'systemctl restart supervisor'
```

## Cost Considerations

- Droplets are billed hourly (monthly cap applies)
- Bandwidth is included (1TB+ on most plans)
- Snapshots and backups are additional
- Use smaller droplet sizes for testing/development
- Delete unused droplets to avoid charges

## Security Best Practices

1. **SSH Keys**: Always use SSH keys (scripts generate them automatically)
2. **Firewalls**: Scripts create droplet-specific firewalls
3. **API Keys**: Never commit API keys to version control
4. **Regular Updates**: Keep droplets updated with security patches
5. **Monitoring**: Enable DigitalOcean monitoring for production deployments
