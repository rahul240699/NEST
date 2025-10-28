#!/usr/bin/env python3
"""
Simple NANDA Adapter - Clean Agent-to-Agent Communication

Simple, clean adapter focused on A2A communication without complexity.
8-10 lines to deploy an agent.
"""

import os
import requests
from typing import Optional, Callable
from python_a2a import run_server
from .agent_bridge import SimpleAgentBridge


class NANDA:
    """Simple NANDA class for clean agent deployment"""
    
    def __init__(self, 
                 agent_id: str,
                 agent_logic: Callable[[str, str], str],
                 port: int = 6000,
                 registry_url: Optional[str] = None,
                 mcp_registry_url: Optional[str] = None,
                 public_url: Optional[str] = None,
                 host: str = "0.0.0.0",
                 enable_telemetry: bool = True,
                 smithery_api_key: Optional[str] = None):
        """
        Create a simple NANDA agent
        
        Args:
            agent_id: Unique agent identifier
            agent_logic: Function that takes (message: str, conversation_id: str) -> response: str
            port: Port to run on
            registry_url: Optional registry URL for agent discovery
            mcp_registry_url: Optional MCP registry URL for MCP server discovery
            public_url: Public URL for agent registration (e.g., https://yourdomain.com:6000)
            host: Host to bind to
            enable_telemetry: Enable telemetry logging (optional)
            smithery_api_key: Optional Smithery API key for MCP server authentication
        """
        self.agent_id = agent_id
        self.agent_logic = agent_logic
        self.port = port
        self.registry_url = registry_url
        self.mcp_registry_url = mcp_registry_url
        self.public_url = public_url
        self.host = host
        self.enable_telemetry = enable_telemetry
        self.smithery_api_key = smithery_api_key
        
        # Initialize telemetry if enabled
        self.telemetry = None
        if enable_telemetry:
            try:
                from ..telemetry.telemetry_system import TelemetrySystem
                self.telemetry = TelemetrySystem(agent_id)
                print(f"📊 Telemetry enabled for {agent_id}")
            except ImportError:
                print(f"⚠️ Telemetry requested but module not available")
        
        # Create the bridge with optional features
        self.bridge = SimpleAgentBridge(
            agent_id=agent_id,
            agent_logic=agent_logic,
            registry_url=registry_url,
            telemetry=self.telemetry,
            mcp_registry_url=mcp_registry_url,
            smithery_api_key=smithery_api_key
        )
        
        print(f"🤖 NANDA Agent '{agent_id}' created")
        if registry_url:
            print(f"🌐 Registry: {registry_url}")
        if public_url:
            print(f"🔗 Public URL: {public_url}")
    
    def start(self, register: bool = True):
        """Start the agent server"""
        # Register with registry if provided
        if register and self.registry_url and self.public_url:
            self._register()
        
        print(f"🚀 Starting agent '{self.agent_id}' on {self.host}:{self.port}")
        
        # Start the A2A server
        run_server(self.bridge, host=self.host, port=self.port)
    
    def _register(self):
        """Register agent with registry"""
        try:
            data = {
                "agent_id": self.agent_id,
                "agent_url": self.public_url
            }
            response = requests.post(f"{self.registry_url}/register", json=data, timeout=10)
            if response.status_code == 200:
                print(f"✅ Agent '{self.agent_id}' registered successfully")
            else:
                print(f"⚠️ Failed to register agent: HTTP {response.status_code}")
        except Exception as e:
            print(f"⚠️ Registration error: {e}")
    
    def stop(self):
        """Stop the agent and cleanup telemetry"""
        if self.telemetry:
            self.telemetry.stop()
        print(f"🛑 Stopping agent '{self.agent_id}'")