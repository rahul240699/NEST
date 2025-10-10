#!/usr/bin/env python3
"""
Core components for the Streamlined NANDA Adapter
"""

from .adapter import NANDA, StreamlinedAdapter
from .agent_bridge import SimpleAgentBridge
from .registry_factory import create_registry_client, get_default_registry_client

__all__ = [
    "NANDA",
    "create_registry_client",
    "get_default_registry_client",
    "StreamlinedAdapter",
    "SimpleAgentBridge"
]