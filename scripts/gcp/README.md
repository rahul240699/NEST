# GCP Deployment Scripts for NANDA Agents

This directory contains Google Cloud Platform (GCP) deployment scripts for NANDA agents with full MCP (Model Context Protocol) integration.

## Prerequisites

1. **GCP Account**: Active Google Cloud Platform account
2. **gcloud CLI**: Installed and configured
3. **Project Setup**: GCP project with Compute Engine API enabled
4. **Authentication**: Valid gcloud authentication

### Setup GCP Environment

```bash
# Install gcloud CLI (if not installed)
# Follow: https://cloud.google.com/sdk/docs/install

# Authenticate with GCP
gcloud auth login

# Set your project ID
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs
gcloud services enable compute.googleapis.com
```

## Scripts Overview

### Single Agent Deployment (`single-agent-deployment.sh`)

Deploy a single NANDA agent on GCP Compute Engine with full MCP support.

**Usage:**

```bash
bash scripts/gcp/single-agent-deployment.sh \
  "agent-id" \
  "anthropic-api-key" \
  "Agent Name" \
  "domain" \
  "specialization" \
  "description" \
  "capabilities" \
  "smithery-api-key" \
  "registry-url" \
  "mcp-registry-url" \
  "port" \
  "zone" \
  "machine-type"
```

**Example:**

```bash
bash scripts/gcp/single-agent-deployment.sh \
  "gcp-data-scientist" \
  "sk-ant-api03-..." \
  "GCP Data Scientist" \
  "data analysis" \
  "analytical and precise AI assistant" \
  "I specialize in data analysis on GCP" \
  "data,analytics,gcp,bigquery" \
  "smithery-key-123..." \
  "http://registry.chat39.com:6900" \
  "https://mcp-registry.ngrok.app" \
  "6000" \
  "us-central1-a" \
  "e2-micro"
```

### Multi-Agent Deployment (`multi-agent-deployment.sh`)

Deploy multiple NANDA agents on a single GCP Compute Engine instance with supervisor process management.

**Usage:**

```bash
bash scripts/gcp/multi-agent-deployment.sh \
  "anthropic-api-key" \
  "agent-config-json" \
  "smithery-api-key" \
  "registry-url" \
  "mcp-registry-url" \
  "zone" \
  "machine-type"
```

**Example:**

```bash
bash scripts/gcp/multi-agent-deployment.sh \
  "sk-ant-api03-..." \
  "scripts/agent_configs/group-01-business-and-finance-experts.json" \
  "smithery-key-123..." \
  "http://registry.chat39.com:6900" \
  "https://mcp-registry.ngrok.app" \
  "us-central1-a" \
  "e2-standard-4"
```

## GCP-Specific Features

### Machine Types

- **e2-micro**: Cost-effective for single agents (free tier eligible)
- **e2-small**: Small workloads, 1-2 agents
- **e2-standard-4**: Recommended for 5-10 agents
- **e2-standard-8**: For 10+ agents or high-traffic scenarios

### Networking

- **Firewall Rules**: Automatically creates rules for agent ports
- **External IP**: Assigns external IP for agent communication
- **Network Tags**: Uses tags for security group management

### Storage

- **Boot Disk**: 20GB (single agent) / 50GB (multi-agent) persistent disk
- **Auto-delete**: Disk deleted when instance is terminated
- **Balanced Persistent Disk**: Good performance/cost balance

### Metadata and Startup Scripts

- **Startup Scripts**: Automated agent installation and configuration
- **Metadata Service**: Used to get external IP for agent registration
- **Labels**: Proper instance labeling for organization

## Environment Variables

All scripts support these environment variables:

- `ANTHROPIC_API_KEY`: Your Claude API key
- `SMITHERY_API_KEY`: Your Smithery API key for MCP server access
- `AGENT_ID`: Unique agent identifier
- `AGENT_NAME`: Display name for the agent
- `REGISTRY_URL`: NANDA registry endpoint
- `MCP_REGISTRY_URL`: MCP server registry endpoint
- `PUBLIC_URL`: Agent's public URL for A2A communication

## MCP Integration

Both scripts include full MCP (Model Context Protocol) support:

### Smithery MCP Servers

```bash
# Test Smithery MCP integration
curl -X POST http://EXTERNAL_IP:PORT/a2a \
  -H "Content-Type: application/json" \
  -d '{"content":{"text":"#smithery:fetch get weather data","type":"text"},"role":"user","conversation_id":"test"}'
```

### NANDA MCP Servers

```bash
# Test NANDA MCP integration
curl -X POST http://EXTERNAL_IP:PORT/a2a \
  -H "Content-Type: application/json" \
  -d '{"content":{"text":"#nanda:nanda-points get balance","type":"text"},"role":"user","conversation_id":"test"}'
```

## Management Commands

### Instance Management

```bash
# SSH into instance
gcloud compute ssh ubuntu@INSTANCE_NAME --zone=ZONE

# View startup logs
gcloud compute instances get-serial-port-output INSTANCE_NAME --zone=ZONE

# Stop instance
gcloud compute instances stop INSTANCE_NAME --zone=ZONE

# Start instance
gcloud compute instances start INSTANCE_NAME --zone=ZONE

# Delete instance
gcloud compute instances delete INSTANCE_NAME --zone=ZONE
```

### Multi-Agent Management (via SSH)

```bash
# Check agent status
sudo supervisorctl status

# Restart all agents
sudo supervisorctl restart all

# Restart specific agent
sudo supervisorctl restart agent_AGENT_ID

# View agent logs
sudo tail -f /var/log/agent_AGENT_ID.out.log
```

## Cost Optimization

### Free Tier Usage

- Use `e2-micro` instances in eligible regions
- Deploy in `us-central1-a`, `us-east1-b`, or `us-west1-b`
- Monitor usage to stay within free tier limits

### Cost Management

```bash
# Set up budget alerts
gcloud billing budgets create --billing-account=BILLING_ACCOUNT_ID \
  --display-name="NANDA Agents Budget" \
  --budget-amount=50USD

# Use preemptible instances for cost savings
gcloud compute instances create INSTANCE_NAME \
  --preemptible \
  --zone=ZONE \
  --machine-type=MACHINE_TYPE
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**

   ```bash
   gcloud auth login
   gcloud auth list
   ```

2. **API Not Enabled**

   ```bash
   gcloud services enable compute.googleapis.com
   ```

3. **Quota Exceeded**

   ```bash
   gcloud compute project-info describe --format="table(quotas.metric,quotas.limit,quotas.usage)"
   ```

4. **Instance Not Starting**

   ```bash
   gcloud compute instances get-serial-port-output INSTANCE_NAME --zone=ZONE
   ```

5. **Agent Not Responding**

   ```bash
   gcloud compute ssh ubuntu@INSTANCE_NAME --zone=ZONE
   sudo tail -f /var/log/startup-script.log
   ```

## Security Best Practices

1. **Firewall Rules**: Scripts create specific rules for required ports only
2. **Service Accounts**: Use default Compute Engine service account with minimal permissions
3. **SSH Keys**: Automatically managed through GCP project metadata
4. **Network Security**: Consider using VPC and private subnets for production
5. **Secrets Management**: Consider using GCP Secret Manager for API keys

## Monitoring and Logging

### GCP Logging

```bash
# View logs in Cloud Logging
gcloud logging read "resource.type=gce_instance AND resource.labels.instance_id=INSTANCE_ID"
```

### Custom Metrics

- Agent response times
- MCP server connection health
- A2A communication success rates

## Support

For GCP-specific issues:

- Check [GCP Compute Engine documentation](https://cloud.google.com/compute/docs)
- Review [GCP troubleshooting guides](https://cloud.google.com/compute/docs/troubleshooting)
- Monitor [GCP status page](https://status.cloud.google.com/)

For NANDA-specific issues:

- Check agent logs: `/var/log/agent_*.out.log`
- Review startup script logs: `/var/log/startup-script.log`
- Test MCP functionality with provided curl commands
