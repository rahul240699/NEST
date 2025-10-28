# NANDA MCP Server Registry

Simple Flask-based registry for NANDA MCP servers using MongoDB.

## Setup

1. Install dependencies:
```bash
cd test/mockup_mcp_registry
pip install -r requirements.txt
```

2. Make sure MongoDB is running on localhost:27017

3. Run the registry:
```bash
python app.py
```

4. The registry will be available at `http://localhost:5000`

## Endpoints

- `GET /` - Health check
- `GET /mcp_servers` - List all servers
- `GET /mcp_servers/<name>` - Get specific server
- `POST /mcp_servers` - Register new server
- `DELETE /mcp_servers/<name>` - Delete server

## Testing

Test the nanda-points server:
```bash
curl http://localhost:5001/mcp_servers/nanda-points
```

## Ngrok Setup

After starting the registry, expose it with ngrok:
```bash
ngrok http 5001
```

Then update your NANDA agents to use the ngrok URL as the MCP registry URL.

## Pre-loaded Servers

The registry comes pre-loaded with:
- `nanda-points`: Your NANDA Points MCP server