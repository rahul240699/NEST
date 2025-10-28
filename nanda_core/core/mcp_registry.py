#!/usr/bin/env python3
"""
MCP Registry Client for the NANDA Adapter
Handles MCP server discovery from various registries (Smithery, NANDA)
"""

import json
import base64
import logging
import requests
from typing import Optional, Dict, Any
import os


class MCPRegistry:
    """Handles MCP server discovery from various registries (Smithery, NANDA)"""

    def __init__(self, mcp_registry_url: str, agent_registry_url: str = None):
        # Separate URLs for MCP registry and agent registry
        self.mcp_registry_url = mcp_registry_url  # For NANDA MCP server lookups
        self.agent_registry_url = agent_registry_url or "http://registry.chat39.com:6900"  # For agent registry queries
        self.smithery_api_key = os.getenv("SMITHERY_API_KEY", "")
        
        # Debug logging
        logger = logging.getLogger(__name__)
        logger.info(f"🔧 [MCPRegistry] Initialized with mcp_registry_url: {self.mcp_registry_url}")
        logger.info(f"🔧 [MCPRegistry] Agent registry URL: {self.agent_registry_url}")
        logger.info(f"🔧 [MCPRegistry] Smithery API key: {self.smithery_api_key[:10]}..." if self.smithery_api_key else "🔧 [MCPRegistry] No Smithery API key")

    def get_mcp_server_info(self, registry_provider: str, server_name: str) -> Optional[Dict[str, Any]]:
        """Unified method to get MCP server info from any registry type"""
        try:
            logger = logging.getLogger(__name__)
            logger.info(f"🔍 [MCPRegistry] Getting server info for {registry_provider}:{server_name}")
            
            if registry_provider.lower() == "smithery":
                return self.get_smithery_mcp_server_info_complete(server_name)
            elif registry_provider.lower() == "nanda":
                return self.get_nanda_mcp_server_info(server_name)
            else:
                logger.error(f"❌ [MCPRegistry] Unknown registry provider: {registry_provider}")
                return None
                
        except Exception as e:
            logger.error(f"❌ [MCPRegistry] Error getting server info for {registry_provider}:{server_name}: {e}")
            return None

    def get_server_config(self, registry_provider: str, qualified_name: str) -> Optional[Dict[str, Any]]:
        """Query agent registry for MCP server configuration"""
        try:
            logger = logging.getLogger(__name__)

            query_url = f"{self.agent_registry_url}/get_mcp_registry"
            params = {
                'registry_provider': registry_provider,
                'qualified_name': qualified_name
            }
            
            logger.info(f"🌐 [MCPRegistry] Querying agent registry: {query_url} with params: {params}")
            
            response = requests.get(query_url, params=params)
            
            logger.info(f"🌐 [MCPRegistry] Registry response status: {response.status_code}")
            
            if response.status_code == 200:
                result = response.json()
                logger.info(f"🌐 [MCPRegistry] Registry response data: {result}")
                
                endpoint = result.get("endpoint")
                config = result.get("config")
                config_json = json.loads(config) if isinstance(config, str) else config
                registry_name = result.get("registry_provider")

                server_config = {
                    "endpoint": endpoint,
                    "config": config_json,
                    "registry_provider": registry_name
                }
                
                logger.info(f"🌐 [MCPRegistry] Parsed server config: {server_config}")
                return server_config
            else:
                logger.warning(f"🌐 [MCPRegistry] Registry query failed with status {response.status_code}: {response.text}")
                return None

        except Exception as e:
            logger.error(f"❌ [MCPRegistry] Error querying MCP registry: {e}")
            return None

    def build_server_url(self, endpoint: str, config: Dict[str, Any], registry_provider: str) -> Optional[str]:
        """Build the final MCP server URL with authentication"""
        try:
            logger = logging.getLogger(__name__)
            
            logger.info(f"🔧 [MCPRegistry] Building server URL for {registry_provider}")
            logger.info(f"🔧 [MCPRegistry] Endpoint: {endpoint}")
            logger.info(f"🔧 [MCPRegistry] Config: {config}")
            
            if registry_provider == "smithery":
                if not self.smithery_api_key:
                    logger.error(f"❌ [MCPRegistry] SMITHERY_API_KEY not found in environment")
                    return None

                logger.info(f"🔧 [MCPRegistry] Using Smithery API key: {self.smithery_api_key[:10]}...")
                
                config_b64 = base64.b64encode(json.dumps(config).encode()).decode()
                logger.info(f"🔧 [MCPRegistry] Config base64 encoded: {config_b64[:50]}...")
                
                final_url = f"{endpoint}?api_key={self.smithery_api_key}&config={config_b64}"
                logger.info(f"🔧 [MCPRegistry] Final Smithery URL: {final_url[:100]}...")
                
                return final_url
            else:
                logger.info(f"🔧 [MCPRegistry] Using direct endpoint for {registry_provider}: {endpoint}")
                return endpoint
        except Exception as e:
            logger.error(f"❌ [MCPRegistry] Error building server URL: {e}")
            return None

# Legacy lookup method removed - use get_nanda_mcp_server_info() instead

    def get_nanda_mcp_server_info(self, server_name: str) -> Optional[Dict[str, Any]]:
        """Get NANDA MCP server information from MongoDB registry"""
        try:
            logger = logging.getLogger(__name__)
            
            # Query NANDA MCP registry endpoint
            lookup_url = f"{self.mcp_registry_url}/mcp_servers/{server_name}"
            logger.info(f"🔍 [NANDA-MCP] Looking up server '{server_name}' at: {lookup_url}")
            
            response = requests.get(lookup_url, timeout=10)
            logger.info(f"� [NANDA-MCP] Registry response status: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                server_url = data.get("server_url") or data.get("endpoint")
                
                server_info = {
                    "server_name": server_name,
                    "server_url": server_url,
                    "registry_provider": "nanda",
                    "config": data.get("config", {}),
                    "description": data.get("description", ""),
                    "raw_data": data
                }
                
                logger.info(f"✅ [NANDA-MCP] Found server {server_name}: {server_url}")
                return server_info
            else:
                logger.error(f"❌ [NANDA-MCP] Server {server_name} not found (status: {response.status_code})")
                return None
                
        except Exception as e:
            logger.error(f"❌ [NANDA-MCP] Error looking up server {server_name}: {e}")
            return None

    def get_smithery_server_info(self, server_id: str) -> Optional[Dict[str, Any]]:
        """Get server information directly from Smithery registry"""
        try:
            logger = logging.getLogger(__name__)
            
            if not self.smithery_api_key:
                logger.error(f"❌ [SmitheryAPI] SMITHERY_API_KEY not found")
                return None
            
            # Use Smithery's direct API
            smithery_url = f"https://registry.smithery.ai/servers/{server_id}"
            headers = {
                "Authorization": f"Bearer {self.smithery_api_key}"
            }
            
            logger.info(f"🏭 [SmitheryAPI] Querying Smithery registry: {smithery_url}")
            logger.info(f"🏭 [SmitheryAPI] Using API key: {self.smithery_api_key[:10]}...")
            
            response = requests.get(smithery_url, headers=headers, timeout=10)
            logger.info(f"🏭 [SmitheryAPI] Smithery response status: {response.status_code}")
            
            if response.status_code == 200:
                server_info = response.json()
                logger.info(f"🏭 [SmitheryAPI] Smithery server info: {server_info}")
                return server_info
            else:
                logger.error(f"❌ [SmitheryAPI] Failed to get server info: {response.status_code} - {response.text}")
                return None
                
        except Exception as e:
            logger.error(f"❌ [SmitheryAPI] Error querying Smithery API: {e}")
            return None

    def build_smithery_server_url(self, server_info: Dict[str, Any]) -> Optional[str]:
        """Build Smithery MCP server URL from server info"""
        try:
            logger = logging.getLogger(__name__)
            
            # Extract deployment URL and config from Smithery response
            deployment_url = server_info.get("deploymentUrl")
            connections = server_info.get("connections", [])
            
            logger.info(f"🔧 [SmitheryURL] Deployment URL: {deployment_url}")
            logger.info(f"🔧 [SmitheryURL] Connections: {connections}")
            
            if not deployment_url:
                logger.error(f"❌ [SmitheryURL] No deployment URL found in server info")
                return None
            
            # Find the MCP connection (look for http type first, then stdio)
            mcp_connection = None
            for conn in connections:
                if conn.get("type") == "http" and conn.get("deploymentUrl"):
                    mcp_connection = conn
                    break
                elif conn.get("type") == "stdio":
                    mcp_connection = conn
                    break
            
            if mcp_connection and mcp_connection.get("deploymentUrl"):
                mcp_url = mcp_connection.get("deploymentUrl")
                logger.info(f"✅ [SmitheryURL] Using MCP connection URL: {mcp_url}")
                return mcp_url
            elif mcp_connection:
                logger.info(f"✅ [SmitheryURL] Using stdio connection with deployment URL: {deployment_url}")
                return deployment_url
            else:
                logger.warning(f"⚠️ [SmitheryURL] No MCP connection found, using deployment URL directly")
                return deployment_url
            
        except Exception as e:
            logger.error(f"❌ [SmitheryURL] Error building Smithery URL: {e}")
            return None

    def get_smithery_mcp_server_info_complete(self, server_name: str) -> Optional[Dict[str, Any]]:
        """Get complete Smithery MCP server information including built URL"""
        try:
            logger = logging.getLogger(__name__)
            
            logger.info(f"🏭 [SmitheryMCP] Getting server info for: {server_name}")
            
            if not self.smithery_api_key:
                logger.error(f"❌ [SmitheryMCP] SMITHERY_API_KEY not found in environment variables")
                return None
            
            # Get server info from Smithery registry
            server_info = self.get_smithery_server_info(server_name)
            if not server_info:
                logger.error(f"❌ [SmitheryMCP] Smithery MCP server '{server_name}' not found")
                return None
            
            # Build server URL
            server_url = self.build_smithery_server_url(server_info)
            if not server_url:
                logger.error(f"❌ [SmitheryMCP] Failed to build server URL for '{server_name}'")
                return None
            
            # Return complete server information
            complete_info = {
                "server_name": server_name,
                "server_url": server_url,
                "registry_provider": "smithery",
                "deployment_url": server_info.get("deploymentUrl"),
                "connections": server_info.get("connections", []),
                "description": server_info.get("description", ""),
                "raw_data": server_info
            }
            
            logger.info(f"✅ [SmitheryMCP] Built complete server info for {server_name}")
            return complete_info
            
        except Exception as e:
            logger.error(f"❌ [SmitheryMCP] Error getting Smithery server info: {e}", exc_info=True)
            return None