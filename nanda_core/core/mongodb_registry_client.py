#!/usr/bin/env python3
"""
MongoDB Registry Client for NEST Adapter
Implements registry functions using MongoDB collections
"""

import os
import logging
from typing import Optional, Dict, List, Any
from datetime import datetime
from .abstract_registry_client import AbstractRegistryClient

# MongoDB imports
try:
    from pymongo import MongoClient
    from pymongo.errors import ConnectionFailure, OperationFailure
    PYMONGO_AVAILABLE = True
except ImportError:
    PYMONGO_AVAILABLE = False

logger = logging.getLogger(__name__)


class MongoDBRegistryClient(AbstractRegistryClient):
    """MongoDB-based registry client implementation"""
    
    def __init__(self, mongodb_uri: Optional[str] = None, database_name: Optional[str] = None,
                 agents_collection: Optional[str] = None, mcp_collection: Optional[str] = None):
        """
        Initialize MongoDB registry client
        
        Args:
            mongodb_uri: MongoDB connection URI
            database_name: Database name
            agents_collection: Agents collection name
            mcp_collection: MCP servers collection name
        """
        if not PYMONGO_AVAILABLE:
            raise ImportError("pymongo is required for MongoDB registry client. Install with: pip install pymongo")
        
        # Load from environment or use provided values
        self.mongodb_uri = mongodb_uri or os.getenv("MONGODB_URI")
        self.database_name = database_name or os.getenv("MONGODB_DATABASE", "nanda")
        self.agents_collection_name = agents_collection or os.getenv("MONGODB_COLLECTION", "agents")
        self.mcp_collection_name = mcp_collection or os.getenv("MCP_COLLECTION", "mcp_servers")
        
        if not self.mongodb_uri:
            raise ValueError("MongoDB URI is required. Set MONGODB_URI environment variable or pass mongodb_uri parameter")
        
        # Initialize MongoDB client
        try:
            self.client = MongoClient(self.mongodb_uri)
            self.db = self.client[self.database_name]
            self.agents_collection = self.db[self.agents_collection_name]
            self.mcp_collection = self.db[self.mcp_collection_name]
            
            # Test connection
            self.client.admin.command('ping')
            logger.info(f"✅ Connected to MongoDB: {self.database_name}.{self.agents_collection_name}")
            
        except ConnectionFailure as e:
            logger.error(f"❌ Failed to connect to MongoDB: {e}")
            raise
    
    def register_agent(self, agent_id: str, agent_url: str, api_url: Optional[str] = None, 
                      agent_facts_url: Optional[str] = None, service_charge: Optional[float] = None) -> bool:
        """Register an agent with MongoDB"""
        try:
            agent_doc = {
                "agent_id": agent_id,
                "agent_url": agent_url,
                "created_at": datetime.utcnow(),
                "updated_at": datetime.utcnow(),
                "status": "active"
            }
            
            if api_url:
                agent_doc["api_url"] = api_url
            if agent_facts_url:
                agent_doc["agent_facts_url"] = agent_facts_url
            if service_charge is not None:
                agent_doc["service_charge"] = service_charge
            
            # Upsert agent document
            result = self.agents_collection.update_one(
                {"agent_id": agent_id},
                {"$set": agent_doc},
                upsert=True
            )
            
            logger.info(f"✅ Agent {agent_id} registered successfully")
            return True
            
        except Exception as e:
            logger.error(f"❌ Error registering agent {agent_id}: {e}")
            return False
    
    def lookup_agent(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """Look up an agent in MongoDB"""
        try:
            agent_doc = self.agents_collection.find_one({"agent_id": agent_id})
            if agent_doc:
                # Remove MongoDB ObjectId for JSON serialization
                agent_doc.pop('_id', None)
                return agent_doc
            return None
            
        except Exception as e:
            logger.error(f"❌ Error looking up agent {agent_id}: {e}")
            return None
    
    def list_agents(self) -> List[Dict[str, Any]]:
        """List all registered agents from MongoDB"""
        try:
            agents = list(self.agents_collection.find({"status": {"$ne": "deleted"}}))
            # Remove MongoDB ObjectIds
            for agent in agents:
                agent.pop('_id', None)
            return agents
            
        except Exception as e:
            logger.error(f"❌ Error listing agents: {e}")
            return []
    
    def list_clients(self) -> List[Dict[str, Any]]:
        """List all registered clients (same as agents in MongoDB)"""
        return self.list_agents()
    
    def get_agent_metadata(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """Get detailed metadata for an agent"""
        return self.lookup_agent(agent_id)
    
    def search_agents(self, query: str = "", capabilities: List[str] = None, tags: List[str] = None) -> List[Dict[str, Any]]:
        """Search for agents based on criteria"""
        try:
            search_filter = {"status": {"$ne": "deleted"}}
            
            if query:
                # Text search on agent_id, description, or capabilities
                search_filter["$or"] = [
                    {"agent_id": {"$regex": query, "$options": "i"}},
                    {"description": {"$regex": query, "$options": "i"}},
                    {"capabilities": {"$regex": query, "$options": "i"}}
                ]
            
            if capabilities:
                # Search for agents with specific capabilities
                search_filter["capabilities"] = {"$in": capabilities}
            
            if tags:
                # Search for agents with specific tags
                search_filter["tags"] = {"$in": tags}
            
            agents = list(self.agents_collection.find(search_filter))
            # Remove MongoDB ObjectIds
            for agent in agents:
                agent.pop('_id', None)
            return agents
            
        except Exception as e:
            logger.error(f"❌ Error searching agents: {e}")
            return []
    
    def get_mcp_servers(self, registry_provider: Optional[str] = None) -> List[Dict[str, Any]]:
        """Get list of available MCP servers from MongoDB"""
        try:
            search_filter = {}
            if registry_provider:
                search_filter["registry_provider"] = registry_provider
            
            servers = list(self.mcp_collection.find(search_filter))
            # Remove MongoDB ObjectIds
            for server in servers:
                server.pop('_id', None)
            return servers
            
        except Exception as e:
            logger.error(f"❌ Error getting MCP servers: {e}")
            return []
    
    def get_mcp_server_config(self, registry_provider: str, qualified_name: str) -> Optional[Dict[str, Any]]:
        """Get configuration for a specific MCP server"""
        try:
            server_doc = self.mcp_collection.find_one({
                "registry_provider": registry_provider,
                "qualified_name": qualified_name
            })
            
            if server_doc:
                server_doc.pop('_id', None)
                return server_doc
            return None
            
        except Exception as e:
            logger.error(f"❌ Error getting MCP server config: {e}")
            return None
    
    def update_agent_status(self, agent_id: str, status: str, metadata: Optional[Dict[str, Any]] = None) -> bool:
        """Update agent status and metadata"""
        try:
            update_doc = {
                "status": status,
                "updated_at": datetime.utcnow()
            }
            
            if metadata:
                update_doc.update(metadata)
            
            result = self.agents_collection.update_one(
                {"agent_id": agent_id},
                {"$set": update_doc}
            )
            
            return result.modified_count > 0
            
        except Exception as e:
            logger.error(f"❌ Error updating agent status: {e}")
            return False
    
    def unregister_agent(self, agent_id: str) -> bool:
        """Unregister an agent (mark as deleted)"""
        try:
            result = self.agents_collection.update_one(
                {"agent_id": agent_id},
                {"$set": {"status": "deleted", "updated_at": datetime.utcnow()}}
            )
            
            return result.modified_count > 0
            
        except Exception as e:
            logger.error(f"❌ Error unregistering agent: {e}")
            return False
    
    def health_check(self) -> bool:
        """Check if MongoDB is healthy"""
        try:
            self.client.admin.command('ping')
            return True
        except Exception:
            return False
    
    def get_registry_stats(self) -> Optional[Dict[str, Any]]:
        """Get registry statistics from MongoDB"""
        try:
            total_agents = self.agents_collection.count_documents({})
            active_agents = self.agents_collection.count_documents({"status": "active"})
            total_mcp_servers = self.mcp_collection.count_documents({})
            
            return {
                "total_agents": total_agents,
                "active_agents": active_agents,
                "deleted_agents": total_agents - active_agents,
                "total_mcp_servers": total_mcp_servers,
                "database": self.database_name,
                "collections": {
                    "agents": self.agents_collection_name,
                    "mcp_servers": self.mcp_collection_name
                }
            }
            
        except Exception as e:
            logger.error(f"❌ Error getting registry stats: {e}")
            return None
    
    def close(self):
        """Close MongoDB connection"""
        if hasattr(self, 'client'):
            self.client.close()
            logger.info("🔌 MongoDB connection closed")