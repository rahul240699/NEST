#!/usr/bin/env python3
"""
Abstract Registry Client for NEST Adapter
Provides base interface for different registry implementations
"""

from abc import ABC, abstractmethod
from typing import Optional, Dict, List, Any


class AbstractRegistryClient(ABC):
    """Abstract base class for registry clients"""
    
    @abstractmethod
    def register_agent(self, agent_id: str, agent_url: str, api_url: Optional[str] = None, 
                      agent_facts_url: Optional[str] = None, service_charge: Optional[float] = None) -> bool:
        """Register an agent with the registry"""
        pass
    
    @abstractmethod
    def lookup_agent(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """Look up an agent in the registry"""
        pass
    
    @abstractmethod
    def list_agents(self) -> List[Dict[str, Any]]:
        """List all registered agents"""
        pass
    
    @abstractmethod
    def list_clients(self) -> List[Dict[str, Any]]:
        """List all registered clients"""
        pass
    
    @abstractmethod
    def get_agent_metadata(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """Get detailed metadata for an agent"""
        pass
    
    @abstractmethod
    def search_agents(self, query: str = "", capabilities: List[str] = None, tags: List[str] = None) -> List[Dict[str, Any]]:
        """Search for agents based on criteria"""
        pass
    
    @abstractmethod
    def get_mcp_servers(self, registry_provider: Optional[str] = None) -> List[Dict[str, Any]]:
        """Get list of available MCP servers"""
        pass
    
    @abstractmethod
    def get_mcp_server_config(self, registry_provider: str, qualified_name: str) -> Optional[Dict[str, Any]]:
        """Get configuration for a specific MCP server"""
        pass
    
    @abstractmethod
    def update_agent_status(self, agent_id: str, status: str, metadata: Optional[Dict[str, Any]] = None) -> bool:
        """Update agent status and metadata"""
        pass
    
    @abstractmethod
    def unregister_agent(self, agent_id: str) -> bool:
        """Unregister an agent from the registry"""
        pass
    
    @abstractmethod
    def health_check(self) -> bool:
        """Check if the registry is healthy"""
        pass
    
    @abstractmethod
    def get_registry_stats(self) -> Optional[Dict[str, Any]]:
        """Get registry statistics"""
        pass