#!/usr/bin/env python3
"""
Registry Client Factory for NEST Adapter
Creates appropriate registry client based on configuration
"""

import os
import logging
from typing import Optional
from .abstract_registry_client import AbstractRegistryClient
from .registry_client import RegistryClient

logger = logging.getLogger(__name__)

# Try to import MongoDB client
try:
    from .mongodb_registry_client import MongoDBRegistryClient
    MONGODB_AVAILABLE = True
except ImportError:
    MONGODB_AVAILABLE = False


def create_registry_client(registry_url: Optional[str] = None, 
                          use_mongodb: Optional[bool] = None) -> AbstractRegistryClient:
    """
    Create appropriate registry client based on configuration
    
    Args:
        registry_url: Registry URL for HTTP-based client
        use_mongodb: Force MongoDB usage (overrides environment)
        
    Returns:
        Registry client instance
    """
    # Determine which backend to use
    if use_mongodb is None:
        # Check multiple environment variables to determine if MongoDB should be used
        mongodb_uri = os.getenv("MONGODB_URI", "").strip()
        use_mongodb_env = os.getenv("USE_MONGODB_BACKEND", "false").lower() == "true"
        
        # Use MongoDB if explicitly enabled OR if MongoDB URI is provided
        use_mongodb = use_mongodb_env or bool(mongodb_uri)
        
        if use_mongodb:
            logger.info(f"🔍 MongoDB backend selected - USE_MONGODB_BACKEND: {use_mongodb_env}, MONGODB_URI: {'SET' if mongodb_uri else 'NOT SET'}")
    
    if use_mongodb:
        if not MONGODB_AVAILABLE:
            logger.warning("⚠️ MongoDB backend requested but pymongo not available. Install with: pip install pymongo")
            logger.info("🔄 Falling back to HTTP registry client")
            return RegistryClient(registry_url)
        
        try:
            logger.info("🍃 Using MongoDB registry backend")
            return MongoDBRegistryClient()
        except Exception as e:
            logger.error(f"❌ Failed to create MongoDB registry client: {e}")
            logger.info("🔄 Falling back to HTTP registry client")
            return RegistryClient(registry_url)
    else:
        logger.info("🌐 Using HTTP registry backend")
        return RegistryClient(registry_url)


def get_default_registry_client() -> AbstractRegistryClient:
    """
    Get default registry client based on environment configuration
    
    Returns:
        Registry client instance
    """
    registry_url = os.getenv("REGISTRY_URL")
    return create_registry_client(registry_url=registry_url)