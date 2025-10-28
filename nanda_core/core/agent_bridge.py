#!/usr/bin/env python3
"""
Simple Agent Bridge for A2A Communication

Clean, simple bridge focused on agent-to-agent communication.
"""

import os
import uuid
import logging
import requests
import asyncio
from typing import Callable, Optional, Dict, Any
from python_a2a import A2AServer, A2AClient, Message, TextContent, MessageRole, Metadata

# MCP imports
try:
    from .mcp_client import MCPClient
    from .mcp_registry import MCPRegistry
    MCP_AVAILABLE = True
except ImportError:
    MCP_AVAILABLE = False

# Configure logger to capture conversation logs
logger = logging.getLogger(__name__)


class SimpleAgentBridge(A2AServer):
    """Simple Agent Bridge for A2A communication only"""
    
    def __init__(self, 
                 agent_id: str, 
                 agent_logic: Callable[[str, str], str],
                 registry_url: Optional[str] = None,
                 telemetry = None,
                 mcp_registry_url: Optional[str] = None,
                 smithery_api_key: Optional[str] = None):
        super().__init__()
        self.agent_id = agent_id
        self.agent_logic = agent_logic
        self.registry_url = registry_url
        self.telemetry = telemetry
        self.mcp_registry_url = mcp_registry_url
        self.smithery_api_key = smithery_api_key or os.getenv("SMITHERY_API_KEY")
        
        # Debug logging
        logger.info(f"🔧 [AgentBridge] Agent ID: {agent_id}")
        logger.info(f"🔧 [AgentBridge] Registry URL: {registry_url}")
        logger.info(f"🔧 [AgentBridge] MCP Registry URL: {self.mcp_registry_url}")
        logger.info(f"🔧 [AgentBridge] Smithery API Key: {'Set' if self.smithery_api_key else 'Not set'}")
        
    def handle_message(self, msg: Message) -> Message:
        """Handle incoming messages"""
        conversation_id = msg.conversation_id or str(uuid.uuid4())
        
        # Only handle text content
        if not isinstance(msg.content, TextContent):
            return self._create_response(
                msg, conversation_id, 
                "Only text messages supported"
            )
        
        user_text = msg.content.text
        
        # Check if this is an agent-to-agent message in our simple format
        if user_text.startswith("FROM:") and "TO:" in user_text and "MESSAGE:" in user_text:
            return self._handle_incoming_agent_message(user_text, msg, conversation_id)
        
        logger.info(f"📨 [{self.agent_id}] Received: {user_text}")
        logger.info(f"📨 [{self.agent_id}] Message starts with: '{user_text[0] if user_text else 'EMPTY'}'")
        
        # Handle different message types
        try:
            if user_text.startswith("@"):
                # Agent-to-agent message (outgoing)
                logger.info(f"🔄 [{self.agent_id}] Processing @ message")
                return self._handle_agent_message(user_text, msg, conversation_id)
            elif user_text.startswith("#"):
                # MCP server message
                logger.info(f"🔧 [{self.agent_id}] Detected MCP message: {user_text}")
                logger.info(f"🔧 [{self.agent_id}] MCP_AVAILABLE: {MCP_AVAILABLE}")
                try:
                    return self._handle_mcp_message(user_text, msg, conversation_id)
                except Exception as e:
                    logger.error(f"❌ [{self.agent_id}] Error in MCP message handling: {e}")
                    return self._create_response(msg, conversation_id, f"❌ MCP error: {str(e)}")
            elif user_text.startswith("/"):
                # System command
                logger.info(f"⚙️ [{self.agent_id}] Processing / command")
                return self._handle_command(user_text, msg, conversation_id)
            else:
                # Regular message - use agent logic
                if self.telemetry:
                    self.telemetry.log_message_received(self.agent_id, conversation_id)
                
                response = self.agent_logic(user_text, conversation_id)
                return self._create_response(msg, conversation_id, response)
                
        except Exception as e:
            return self._create_response(
                msg, conversation_id, 
                f"Error: {str(e)}"
            )
    
    def _handle_incoming_agent_message(self, user_text: str, msg: Message, conversation_id: str) -> Message:
        """Handle incoming messages from other agents"""
        try:
            lines = user_text.strip().split('\n')
            from_agent = ""
            to_agent = ""
            message_content = ""
            
            for line in lines:
                if line.startswith("FROM:"):
                    from_agent = line[5:].strip()
                elif line.startswith("TO:"):
                    to_agent = line[3:].strip()
                elif line.startswith("MESSAGE:"):
                    message_content = line[8:].strip()
            
            logger.info(f"📨 [{self.agent_id}] ← [{from_agent}]: {message_content}")
            
            # Check if this is a reply (don't respond to replies to avoid infinite loops)
            if message_content.startswith("Response to "):
                logger.info(f"🔄 [{self.agent_id}] Received reply from {from_agent}, displaying to user")
                # Display the reply to user but don't respond back to avoid loops
                return self._create_response(
                    msg, conversation_id, 
                    f"[{from_agent}] {message_content[len('Response to ' + self.agent_id + ': '):]}"
                )
            
            # Process the message through our agent logic
            if self.telemetry:
                self.telemetry.log_message_received(self.agent_id, conversation_id)
            
            response = self.agent_logic(message_content, conversation_id)
            
            # Send response back
            return self._create_response(
                msg, conversation_id, 
                f"Response to {from_agent}: {response}"
            )
            
        except Exception as e:
            logger.error(f"❌ [{self.agent_id}] Error processing incoming agent message: {e}")
            return self._create_response(
                msg, conversation_id,
                f"Error processing message from agent: {str(e)}"
            )

    def _handle_agent_message(self, user_text: str, msg: Message, conversation_id: str) -> Message:
        """Handle messages to other agents (@agent_id message)"""
        parts = user_text.split(" ", 1)
        if len(parts) <= 1:
            return self._create_response(
                msg, conversation_id,
                "Invalid format. Use '@agent_id message'"
            )
        
        target_agent = parts[0][1:]  # Remove @
        message_text = parts[1]
        
        logger.info(f"🔄 [{self.agent_id}] Sending to {target_agent}: {message_text}")
        
        # Look up target agent and send message
        result = self._send_to_agent(target_agent, message_text, conversation_id)
        return self._create_response(msg, conversation_id, result)
    
    def _handle_command(self, user_text: str, msg: Message, conversation_id: str) -> Message:
        """Handle system commands"""
        parts = user_text.split(" ", 1)
        command = parts[0][1:] if len(parts) > 0 else ""
        args = parts[1] if len(parts) > 1 else ""
        
        if command == "help":
            help_text = """Available commands:
/help - Show this help
/ping - Test agent responsiveness  
/status - Show agent status
@agent_id message - Send message to another agent
#nanda:server-name query - Query NANDA MCP server
#smithery:server-name query - Query Smithery MCP server"""
            return self._create_response(msg, conversation_id, help_text)
        
        elif command == "ping":
            return self._create_response(msg, conversation_id, "Pong!")
        
        elif command == "status":
            status = f"Agent: {self.agent_id}, Status: Running"
            if self.registry_url:
                status += f", Registry: {self.registry_url}"
            if self.mcp_registry_url:
                status += f", MCP Registry: {self.mcp_registry_url}"
            return self._create_response(msg, conversation_id, status)
        
        else:
            return self._create_response(
                msg, conversation_id,
                f"Unknown command: {command}. Use /help for available commands"
            )
    
    def _handle_mcp_message(self, user_text: str, msg: Message, conversation_id: str) -> Message:
        """Handle MCP server messages (#registry:server-name query)"""
        logger.info(f"🚀 [{self.agent_id}] _handle_mcp_message called with: {user_text}")
        logger.info(f"🚀 [{self.agent_id}] MCP_AVAILABLE check: {MCP_AVAILABLE}")
        
        if not MCP_AVAILABLE:
            logger.error(f"❌ [{self.agent_id}] MCP not available!")
            return self._create_response(
                msg, conversation_id,
                "❌ MCP support not available. Please install required dependencies."
            )
        
        try:
            logger.info(f"🔧 [{self.agent_id}] Starting MCP message parsing...")
            
            # Parse the MCP message format: #registry:server-name query
            if ':' not in user_text:
                logger.error(f"❌ [{self.agent_id}] No colon found in MCP message: {user_text}")
                return self._create_response(
                    msg, conversation_id,
                    "❌ Invalid MCP message format. Use: #registry:server-name query"
                )
            
            # Extract registry and the rest
            logger.info(f"🔧 [{self.agent_id}] Splitting message at first colon...")
            registry_part, rest = user_text[1:].split(':', 1)
            logger.info(f"🔧 [{self.agent_id}] Registry part: '{registry_part}', Rest: '{rest}'")
            
            if ' ' not in rest:
                logger.error(f"❌ [{self.agent_id}] No space found in rest part: {rest}")
                return self._create_response(
                    msg, conversation_id,
                    "❌ Invalid MCP message format. Use: #registry:server-name query"
                )
            
            server_name, query = rest.split(' ', 1)
            logger.info(f"🔧 [{self.agent_id}] Parsed - Server: '{server_name}', Query: '{query}'")
            
            logger.info(f"🔧 [{self.agent_id}] MCP Request: registry={registry_part}, server={server_name}, query={query[:50]}...")
            
            if not self.mcp_registry_url:
                return self._create_response(
                    msg, conversation_id,
                    "❌ MCP registry URL not configured"
                )
            
            logger.info(f"🔧 [{self.agent_id}] Creating MCPRegistry with MCP URL: {self.mcp_registry_url}")
            logger.info(f"🔧 [{self.agent_id}] Agent registry URL: {self.registry_url}")
            
            # Get server info from registry
            mcp_registry = MCPRegistry(self.mcp_registry_url, self.registry_url)
            server_info = mcp_registry.get_mcp_server_info(registry_part, server_name)
            
            if not server_info:
                result = f"❌ MCP server '{server_name}' not found in {registry_part} registry"
            else:
                server_url = server_info.get("server_url")
                if not server_url:
                    result = f"❌ No server URL found for '{server_name}'"
                else:
                    # Execute MCP query synchronously 
                    try:
                        mcp_result = self._run_mcp_query_sync(server_url, query, registry_part)
                        result = f"🔧 {registry_part.title()} MCP [{server_name}]: {mcp_result}"
                    except Exception as mcp_error:
                        logger.error(f"❌ MCP execution error: {mcp_error}")
                        result = f"❌ MCP server '{server_name}' error: {str(mcp_error)}"
            
            if self.telemetry:
                self.telemetry.log_message_received(self.agent_id, conversation_id)
            
            return self._create_response(msg, conversation_id, result)
                
        except Exception as e:
            logger.error(f"❌ [{self.agent_id}] Error processing MCP message: {e}")
            return self._create_response(
                msg, conversation_id,
                f"❌ Error processing MCP message: {str(e)}"
            )

    def _run_mcp_query_sync(self, server_url: str, query: str, registry_type: str = "unknown") -> str:
        """MCP query execution using threading pattern from payment middleware"""
        import threading
        
        def run_async_mcp():
            # Create new event loop for this thread
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                return loop.run_until_complete(self._run_mcp_async(server_url, query, registry_type))
            finally:
                loop.close()
        
        # Run in separate thread to avoid event loop conflicts
        result_container = {}
        def thread_target():
            result_container['result'] = run_async_mcp()
        
        thread = threading.Thread(target=thread_target)
        thread.start()
        thread.join()
        
        return result_container.get('result', "❌ MCP query failed")
    
    async def _run_mcp_async(self, server_url: str, query: str, registry_type: str = "unknown") -> str:
        """Async MCP operations - just use execute_query directly"""
        try:
            # For Smithery servers, append API key as query parameter
            final_server_url = server_url
            auth_headers = None
            
            if registry_type == "smithery" and hasattr(self, 'smithery_api_key') and self.smithery_api_key:
                # Append API key as query parameter for Smithery
                separator = "&" if "?" in server_url else "?"
                final_server_url = f"{server_url}{separator}api_key={self.smithery_api_key}"
                logger.info(f"🔧 [{self.agent_id}] Added Smithery API key to URL")
            
            # Use execute_query - it handles everything: connection, tool selection, execution
            client = MCPClient()
            result = await client.execute_query(query, final_server_url, auth_headers=auth_headers)
            return result
            
        except Exception as e:
            return f"❌ MCP query failed: {str(e)}"
    
    def _send_to_agent(self, target_agent_id: str, message_text: str, conversation_id: str) -> str:
        """Send message to another agent"""
        try:
            # Look up agent URL
            agent_url = self._lookup_agent(target_agent_id)
            if not agent_url:
                return f"Agent {target_agent_id} not found"
            
            # Ensure URL has /a2a endpoint
            if not agent_url.endswith('/a2a'):
                agent_url = f"{agent_url}/a2a"
            
            logger.info(f"📤 [{self.agent_id}] → [{target_agent_id}]: {message_text}")
            
            # Create simple message with metadata
            simple_message = f"FROM: {self.agent_id}\nTO: {target_agent_id}\nMESSAGE: {message_text}"
            
            # Send message using A2A client
            client = A2AClient(agent_url, timeout=30)
            response = client.send_message(
                Message(
                    role=MessageRole.USER,
                    content=TextContent(text=simple_message),
                    conversation_id=conversation_id,
                    metadata=Metadata(custom_fields={
                        'from_agent_id': self.agent_id,
                        'to_agent_id': target_agent_id,
                        'message_type': 'agent_to_agent'
                    })
                )
            )
            
            if self.telemetry:
                self.telemetry.log_message_sent(target_agent_id, conversation_id)
            
            # Extract the actual response content from the target agent
            logger.info(f"🔍 [{self.agent_id}] Response type: {type(response)}, has parts: {hasattr(response, 'parts') if response else 'None'}")
            if response:
                if hasattr(response, 'parts') and response.parts:
                    response_text = response.parts[0].text
                    logger.info(f"✅ [{self.agent_id}] Received response from {target_agent_id}: {response_text[:100]}...")
                    return f"[{target_agent_id}] {response_text}"
                else:
                    logger.info(f"✅ [{self.agent_id}] Response has no parts, full response: {str(response)[:200]}...")
                    return f"[{target_agent_id}] {str(response)}"
            else:
                logger.info(f"✅ [{self.agent_id}] Message delivered to {target_agent_id}, no response")
                return f"Message sent to {target_agent_id}: {message_text}"
            
        except Exception as e:
            return f"❌ Error sending to {target_agent_id}: {str(e)}"
    
    def _lookup_agent(self, agent_id: str) -> Optional[str]:
        """Look up agent URL in registry or use local discovery"""
        
        # Try registry lookup if available
        if self.registry_url:
            try:
                response = requests.get(f"{self.registry_url}/lookup/{agent_id}", timeout=10)
                if response.status_code == 200:
                    data = response.json()
                    agent_url = data.get("agent_url")
                    logger.info(f"🌐 Found {agent_id} in registry: {agent_url}")
                    return agent_url
            except Exception as e:
                logger.warning(f"🌐 Registry lookup failed: {e}")
        
        # Fallback to local discovery (for testing)
        local_agents = {
            "test_agent": "http://localhost:6000",
        }
        
        if agent_id in local_agents:
            logger.info(f"🏠 Found {agent_id} locally: {local_agents[agent_id]}")
            return local_agents[agent_id]
        
        return None
    
    def _create_response(self, original_msg: Message, conversation_id: str, text: str) -> Message:
        """Create a response message"""
        return Message(
            role=MessageRole.AGENT,
            content=TextContent(text=f"[{self.agent_id}] {text}"),
            parent_message_id=original_msg.message_id,
            conversation_id=conversation_id
        )