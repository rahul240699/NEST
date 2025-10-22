# AWS Deployment Scripts for NANDA Agents

This directory contains Amazon Web Services (AWS) deployment scripts for NANDA agents with full MCP (Model Context Protocol) integration.

## Prerequisites

1. **AWS Account**: Active Amazon Web Services account
2. **AWS CLI**: Installed and configured with credentials
3. **IAM Permissions**: EC2, VPC, and security group management permissions
4. **Key Pair**: SSH key pair for instance access (created automatically)

### Setup AWS Environment

```bash
# Install AWS CLI (if not installed)
# Follow: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

# Configure AWS credentials
aws configure
# Enter your Access Key ID, Secret Access Key, Default region, and output format

# Verify configuration
aws sts get-caller-identity
```

## Scripts Overview

### Single Agent Deployment (`single-agent-deployment.sh`)

Deploy a single NANDA agent on AWS EC2 with full MCP support.

**Usage:**
```bash
bash scripts/aws/single-agent-deployment.sh \
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
  "region" \
  "instance-type"
```

**Example:**
```bash
bash scripts/aws/single-agent-deployment.sh \
  "aws-data-scientist" \
  "sk-ant-api03-..." \
  "AWS Data Scientist" \
  "data analysis" \
  "analytical and precise AI assistant" \
  "I specialize in data analysis on AWS" \
  "data,analytics,aws,sagemaker" \
  "smithery-key-123..." \
  "http://registry.chat39.com:6900" \
  "https://mcp-registry.ngrok.app" \
  "6000" \
  "us-east-1" \
  "t3.micro"
```

### Multi-Agent Deployment (`multi-agent-deployment.sh`)

Deploy multiple NANDA agents on a single AWS EC2 instance with supervisor process management.

**Usage:**
```bash
bash scripts/aws/multi-agent-deployment.sh \
  "anthropic-api-key" \
  "agent-config-json" \
  "smithery-api-key" \
  "registry-url" \
  "mcp-registry-url" \
  "region" \
  "instance-type"
```

**Example:**
```bash
bash scripts/aws/multi-agent-deployment.sh \
  "sk-ant-api03-..." \
  "scripts/agent_configs/group-01-business-and-finance-experts.json" \
  "smithery-key-123..." \
  "http://registry.chat39.com:6900" \
  "https://mcp-registry.ngrok.app" \
  "us-east-1" \
  "t3.xlarge"
```

## AWS-Specific Features

### Instance Types

- **t3.micro**: Free tier eligible, single agent
- **t3.small**: 1-2 agents, light workloads
- **t3.medium**: 3-5 agents
- **t3.large/xlarge**: 5-10+ agents, recommended for multi-agent deployments

### Networking

- **Security Groups**: Automatically created with required ports (SSH + agent ports)
- **VPC**: Uses default VPC with public subnets
- **Elastic IP**: Public IP automatically assigned
- **Internet Gateway**: Required for agent communication

### Storage

- **EBS Volumes**: GP3 storage with auto-delete enabled
- **Root Volume**: 20GB (single) / 50GB (multi-agent)
- **Encryption**: Available but not enabled by default

### AMI and User Data

- **Ubuntu 22.04 LTS**: Reliable, well-supported base image
- **User Data Scripts**: Automated installation and configuration
- **IMDSv2**: Secure metadata service for IP retrieval

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
curl -X POST http://PUBLIC_IP:PORT/a2a \
  -H "Content-Type: application/json" \
  -d '{"content":{"text":"#smithery:fetch get weather data","type":"text"},"role":"user","conversation_id":"test"}'
```

### NANDA MCP Servers
```bash
# Test NANDA MCP integration
curl -X POST http://PUBLIC_IP:PORT/a2a \
  -H "Content-Type: application/json" \
  -d '{"content":{"text":"#nanda:nanda-points get balance","type":"text"},"role":"user","conversation_id":"test"}'
```

## Management Commands

### Instance Management
```bash
# SSH into instance
ssh -i nanda-agent-key.pem ubuntu@PUBLIC_IP

# View instance details
aws ec2 describe-instances --instance-ids INSTANCE_ID

# Stop instance
aws ec2 stop-instances --instance-ids INSTANCE_ID

# Start instance
aws ec2 start-instances --instance-ids INSTANCE_ID

# Terminate instance
aws ec2 terminate-instances --instance-ids INSTANCE_ID
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
- Use `t3.micro` instances (750 hours/month free)
- Deploy in regions with free tier availability
- Monitor usage through AWS Cost Explorer

### Cost Management
```bash
# Set up billing alerts
aws budgets create-budget --account-id ACCOUNT_ID \
  --budget file://budget.json

# Use Spot instances for cost savings (add to launch config)
--instance-market-options '{"MarketType":"spot","SpotOptions":{"MaxPrice":"0.05"}}'
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**
   ```bash
   aws configure list
   aws sts get-caller-identity
   ```

2. **Permission Denied**
   - Check IAM permissions for EC2, VPC operations
   - Ensure AWS CLI has proper credentials

3. **Security Group Issues**
   ```bash
   aws ec2 describe-security-groups --group-ids sg-xxxxx
   ```

4. **Instance Launch Failures**
   ```bash
   aws ec2 describe-instances --instance-ids i-xxxxx
   aws logs describe-log-groups
   ```

5. **Agent Not Responding**
   ```bash
   ssh -i nanda-agent-key.pem ubuntu@PUBLIC_IP
   sudo tail -f /var/log/user-data.log
   ```

## Security Best Practices

1. **Key Management**: Scripts generate SSH keys automatically
2. **Security Groups**: Minimal port exposure (SSH + required agent ports)
3. **IAM Roles**: Consider using instance profiles instead of access keys
4. **VPC Security**: Consider private subnets with NAT Gateway for production
5. **Secrets**: Use AWS Secrets Manager for production API key management

## Monitoring and Logging

### CloudWatch Integration
```bash
# View logs
aws logs describe-log-streams --log-group-name /var/log/user-data

# Create custom metrics
aws cloudwatch put-metric-data --namespace "NANDA/Agents" \
  --metric-data MetricName=AgentHealth,Value=1
```

### Custom Monitoring
- Agent response times via CloudWatch
- MCP server connection health
- A2A communication success rates

## Regions and Availability Zones

### Recommended Regions
- **us-east-1**: Virginia (lowest cost, most services)
- **us-west-2**: Oregon (good performance, lower latency to West Coast)
- **eu-west-1**: Ireland (European operations)
- **ap-southeast-1**: Singapore (Asian operations)

### Multi-AZ Deployment
```bash
# Deploy across multiple AZs for high availability
bash single-agent-deployment.sh ... us-east-1a
bash single-agent-deployment.sh ... us-east-1b
```

## Support

For AWS-specific issues:
- Check [AWS EC2 documentation](https://docs.aws.amazon.com/ec2/)
- Review [AWS troubleshooting guides](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/troubleshooting.html)
- Monitor [AWS Service Health Dashboard](https://health.aws.amazon.com/health/status)

For NANDA-specific issues:
- Check agent logs: `/var/log/agent_*.out.log`
- Review user-data logs: `/var/log/user-data.log`
- Test MCP functionality with provided curl commands

## Advanced Features

### Auto Scaling Groups
Consider setting up Auto Scaling for production workloads to handle varying demand.

### Load Balancing
Use Application Load Balancer for distributing traffic across multiple agent instances.

### CloudFormation
Convert deployment scripts to CloudFormation templates for infrastructure as code.

### ECS/EKS Deployment
Consider containerizing agents for deployment on ECS or EKS for better scalability.