#!/usr/bin/env python3
"""
Simple NANDA MCP Server Registry
Provides endpoints to register and discover NANDA MCP servers
"""

from flask import Flask, request, jsonify
from pymongo import MongoClient
from datetime import datetime
import os
import logging

app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# MongoDB connection
MONGO_URI = os.getenv('MONGO_URI', 'mongodb://localhost:27017/')
DB_NAME = os.getenv('DB_NAME', 'nanda')
COLLECTION_NAME = os.getenv('COLLECTION_NAME', 'mcp_servers')

try:
    client = MongoClient(MONGO_URI)
    db = client[DB_NAME]
    collection = db[COLLECTION_NAME]
    logger.info(f"✅ Connected to MongoDB: {MONGO_URI}")
    logger.info(f"✅ Using database: {DB_NAME}, collection: {COLLECTION_NAME}")
except Exception as e:
    logger.error(f"❌ Failed to connect to MongoDB: {e}")
    exit(1)

@app.route('/', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({
        "service": "NANDA MCP Registry",
        "status": "running",
        "mongodb": "connected",
        "timestamp": datetime.now().isoformat()
    })

@app.route('/mcp_servers', methods=['GET'])
def list_servers():
    """List all MCP servers"""
    try:
        servers = list(collection.find({}, {'_id': 0}))
        return jsonify({
            "servers": servers,
            "count": len(servers)
        })
    except Exception as e:
        logger.error(f"Error listing servers: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/mcp_servers/<server_name>', methods=['GET'])
def get_server(server_name):
    """Get specific MCP server by name"""
    try:
        server = collection.find_one(
            {"qualified_name": server_name}, 
            {'_id': 0}
        )
        
        if server:
            logger.info(f"📡 Found MCP server: {server_name}")
            return jsonify(server)
        else:
            logger.warning(f"🔍 MCP server not found: {server_name}")
            return jsonify({"error": f"MCP server '{server_name}' not found"}), 404
            
    except Exception as e:
        logger.error(f"Error getting server {server_name}: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/mcp_servers', methods=['POST'])
def register_server():
    """Register a new MCP server"""
    try:
        data = request.json
        
        # Validate required fields
        required_fields = ['qualified_name', 'server_url']
        for field in required_fields:
            if field not in data:
                return jsonify({"error": f"Missing required field: {field}"}), 400
        
        # Add metadata
        server_doc = {
            "qualified_name": data['qualified_name'],
            "server_url": data['server_url'],
            "endpoint": data.get('endpoint', data['server_url']),
            "description": data.get('description', ''),
            "tags": data.get('tags', []),
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat()
        }
        
        # Update or insert
        result = collection.replace_one(
            {"qualified_name": data['qualified_name']},
            server_doc,
            upsert=True
        )
        
        if result.upserted_id:
            logger.info(f"✅ Registered new MCP server: {data['qualified_name']}")
            return jsonify({"message": "Server registered successfully", "server": server_doc}), 201
        else:
            logger.info(f"🔄 Updated existing MCP server: {data['qualified_name']}")
            return jsonify({"message": "Server updated successfully", "server": server_doc}), 200
            
    except Exception as e:
        logger.error(f"Error registering server: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/mcp_servers/<server_name>', methods=['DELETE'])
def delete_server(server_name):
    """Delete an MCP server"""
    try:
        result = collection.delete_one({"qualified_name": server_name})
        
        if result.deleted_count > 0:
            logger.info(f"🗑️ Deleted MCP server: {server_name}")
            return jsonify({"message": f"Server '{server_name}' deleted successfully"})
        else:
            return jsonify({"error": f"Server '{server_name}' not found"}), 404
            
    except Exception as e:
        logger.error(f"Error deleting server {server_name}: {e}")
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    # Initialize with your nanda-points server
    try:
        nanda_points_server = {
            "qualified_name": "nanda-points",
            "server_url": "https://p01--nanda-points-mcp--qvf8hqwjtv29.code.run/mcp",
            "endpoint": "https://p01--nanda-points-mcp--qvf8hqwjtv29.code.run/mcp",
            "description": "NANDA Points MCP Server - manages user points and rewards",
            "tags": ["points", "rewards", "nanda"],
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat()
        }
        
        result = collection.replace_one(
            {"qualified_name": "nanda-points"},
            nanda_points_server,
            upsert=True
        )
        
        if result.upserted_id:
            logger.info(f"✅ Initialized with nanda-points server")
        else:
            logger.info(f"🔄 Updated nanda-points server configuration")
            
    except Exception as e:
        logger.error(f"❌ Error initializing nanda-points server: {e}")
    
    logger.info("🚀 Starting NANDA MCP Registry on localhost:5001")
    app.run(host='0.0.0.0', port=5001, debug=True)