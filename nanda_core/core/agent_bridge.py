#!/usr/bin/env python3
"""
Simple Agent Bridge for A2A Communication

Clean, simple bridge focused on agent-to-agent communication.
"""

import os
import uuid
import logging
import requests
from typing import Callable, Optional, Dict, Any
from python_a2a import A2AServer, A2AClient, Message, TextContent, MessageRole, Metadata

# Configure logger to capture conversation logs
logger = logging.getLogger(__name__)


class SimpleAgentBridge(A2AServer):
    """Simple Agent Bridge for A2A communication only"""
    
    def __init__(self, 
                 agent_id: str, 
                 agent_logic: Callable[[str, str], str],
                 registry_url: Optional[str] = None,
                 telemetry = None,
                 payment_middleware = None):
        super().__init__()
        self.agent_id = agent_id
        self.agent_logic = agent_logic
        self.registry_url = registry_url
        self.telemetry = telemetry
        self.payment_middleware = payment_middleware
        
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
        
        # Extract receipt_id from message first (for both A2A and incoming messages)
        receipt_id = None
        original_text = user_text
        
        # Check for receipt in message
        if self.payment_middleware:
            receipt_id = self.payment_middleware.extract_receipt_from_message(user_text)
            if receipt_id:
                # Remove receipt from message text for processing
                import re
                user_text = re.sub(r'\s*#receipt:[a-zA-Z0-9\-]+', '', user_text).strip()

        # Handle different message types
        try:
            if user_text.startswith("@"):
                # Agent-to-agent message (outgoing) - payment logic handled in _handle_agent_message
                return self._handle_agent_message(user_text, msg, conversation_id)
            elif user_text.startswith("/"):
                # System command
                return self._handle_command(user_text, msg, conversation_id)
            else:
                # Regular user message - no payment check needed for direct user messages
                # Process regular message - use agent logic
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
            
            # PAYMENT CHECK: Only for incoming A2A messages from other agents
            if self.payment_middleware:
                # Extract receipt from message content
                receipt_id = self.payment_middleware.extract_receipt_from_message(message_content)
                
                # Check if THIS agent requires payment
                payment_req = self.payment_middleware.check_payment_requirement(self.agent_id)
                
                if payment_req.status.value == "required":  # Use .value to get enum value
                    if not receipt_id:
                        # No receipt provided - return 402 payment required
                        return self._create_response(
                            msg, conversation_id,
                            f"[payment-client-agent-v2-1b4dab] 402-PAYMENT-REQUIRED: This agent requires {payment_req.amount} NP per request. Please provide payment receipt."
                        )
                    else:
                        # Receipt provided - validate it
                        import asyncio
                        try:
                            payment_result = asyncio.get_event_loop().run_until_complete(
                                self.payment_middleware.validate_receipt(receipt_id)
                            )
                            if payment_result.status.value != "paid":  # Use .value to get enum value
                                return self._create_response(
                                    msg, conversation_id,
                                    f"[payment-client-agent-v2-1b4dab] 402-PAYMENT-REQUIRED: Invalid receipt {receipt_id}. Please provide valid payment receipt."
                                )
                            else:
                                logger.info(f"💰 Payment validated for {self.agent_id}: {payment_result.message}")
                                # Remove receipt from message for processing
                                import re
                                message_content = re.sub(r'\s*#receipt:[a-zA-Z0-9\-]+', '', message_content).strip()
                        except Exception as e:
                            logger.error(f"Payment validation error: {e}")
                            return self._create_response(
                                msg, conversation_id,
                                f"[payment-client-agent-v2-1b4dab] ❌ Payment validation error: {str(e)}"
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
@agent_id message - Send message to another agent"""
            return self._create_response(msg, conversation_id, help_text)
        
        elif command == "ping":
            return self._create_response(msg, conversation_id, "Pong!")
        
        elif command == "status":
            status = f"Agent: {self.agent_id}, Status: Running"
            if self.registry_url:
                status += f", Registry: {self.registry_url}"
            return self._create_response(msg, conversation_id, status)
        
        else:
            return self._create_response(
                msg, conversation_id,
                f"Unknown command: {command}. Use /help for available commands"
            )
    
    def _send_to_agent(self, target_agent_id: str, message_text: str, conversation_id: str) -> str:
        """Send message to another agent with payment handling"""
        try:
            # Look up agent URL
            agent_url = self._lookup_agent(target_agent_id)
            if not agent_url:
                return f"Agent {target_agent_id} not found"
            
            # Ensure URL has /a2a endpoint
            if not agent_url.endswith('/a2a'):
                agent_url = f"{agent_url}/a2a"
            
            logger.info(f"📤 [{self.agent_id}] → [{target_agent_id}]: {message_text}")
            
            # Check if message already has receipt (for retry scenarios)
            receipt_id = None
            if self.payment_middleware:
                receipt_id = self.payment_middleware.extract_receipt_from_message(message_text)
            
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
                self.telemetry.log_agent_message_sent(self.agent_id, target_agent_id, conversation_id)
            
            # Extract the actual response content from the target agent
            logger.info(f"🔍 [{self.agent_id}] Response type: {type(response)}, has parts: {hasattr(response, 'parts') if response else 'None'}")
            if response:
                if hasattr(response, 'parts') and response.parts:
                    response_text = response.parts[0].text
                elif hasattr(response, 'content') and hasattr(response.content, 'text'):
                    response_text = response.content.text
                else:
                    response_text = str(response)
                
                logger.info(f"✅ [{self.agent_id}] Received response from {target_agent_id}: {response_text[:100]}...")
                
                # Check if response is a payment request (402)
                if "402-PAYMENT-REQUIRED" in response_text and self.payment_middleware:
                    logger.info(f"🔍 Detected 402 response: {response_text[:100]}...")
                    
                    # Extract amount from payment request
                    import re
                    amount_match = re.search(r'(\d+(?:\.\d+)?)\s*NP', response_text)
                    if amount_match:
                        amount = float(amount_match.group(1))
                        logger.info(f"💰 Payment required: {amount} NP for {target_agent_id}")
                        logger.info(f"🚀 Starting automatic payment processing...")
                        
                        # Automatically process payment
                        try:
                            import asyncio
                            payment_result = asyncio.get_event_loop().run_until_complete(
                                self.payment_middleware.process_payment(
                                    self.agent_id, 
                                    target_agent_id, 
                                    int(amount)  # Convert to int for NP
                                )
                            )
                            
                            logger.info(f"💳 Payment result: {payment_result.status} - {payment_result.message}")
                            
                            if payment_result.status.value == "paid":  # Use .value for enum
                                # Payment successful - retry request with receipt
                                logger.info(f"✅ Payment processed: {payment_result.receipt_id}")
                                
                                # Retry with receipt in message
                                retry_message = f"{message_text} #receipt:{payment_result.receipt_id}"
                                retry_simple_message = f"FROM: {self.agent_id}\nTO: {target_agent_id}\nMESSAGE: {retry_message}"
                                
                                logger.info(f"🔄 Retrying request with receipt: {payment_result.receipt_id}")
                                
                                # Retry the request
                                retry_response = client.send_message(
                                    Message(
                                        role=MessageRole.USER,
                                        content=TextContent(text=retry_simple_message),
                                        conversation_id=conversation_id,
                                        metadata=Metadata(custom_fields={
                                            'from_agent_id': self.agent_id,
                                            'to_agent_id': target_agent_id,
                                            'message_type': 'agent_to_agent_paid'
                                        })
                                    )
                                )
                                
                                if retry_response:
                                    if hasattr(retry_response, 'parts') and retry_response.parts:
                                        retry_text = retry_response.parts[0].text
                                    elif hasattr(retry_response, 'content') and hasattr(retry_response.content, 'text'):
                                        retry_text = retry_response.content.text
                                    else:
                                        retry_text = str(retry_response)
                                    
                                    logger.info(f"✅ Retry successful: {retry_text[:100]}...")
                                    return f"[{target_agent_id}] {retry_text}"
                                else:
                                    return f"[{self.agent_id}] Payment processed, message sent to {target_agent_id}"
                            else:
                                # Payment failed
                                logger.error(f"❌ Payment failed: {payment_result.message}")
                                return f"[{self.agent_id}] Payment failed: {payment_result.message}"
                                
                        except Exception as e:
                            logger.error(f"❌ Error during payment processing: {e}")
                            return f"[{self.agent_id}] Payment processing error: {str(e)}"
                    else:
                        logger.error(f"❌ Could not extract amount from payment request: {response_text}")
                        return f"[{target_agent_id}] {response_text}"
                else:
                    # Normal response (not a payment request)
                    return f"[{target_agent_id}] {response_text}"
            else:
                logger.info(f"✅ [{self.agent_id}] Message delivered to {target_agent_id}, no response")
                return f"Message sent to {target_agent_id}: {message_text}"
            
        except Exception as e:
            return f"❌ Error sending to {target_agent_id}: {str(e)}"
    
    def _lookup_agent(self, agent_id: str) -> Optional[str]:
        """Look up agent URL in registry or use local discovery"""
        
        # Try payment middleware registry first (uses MongoDB if available)
        if self.payment_middleware and hasattr(self.payment_middleware, 'registry_client') and self.payment_middleware.registry_client:
            try:
                agent_info = self.payment_middleware.registry_client.lookup_agent(agent_id)
                if agent_info and 'agent_url' in agent_info:
                    agent_url = agent_info['agent_url']
                    logger.info(f"🍃 Found {agent_id} in MongoDB registry: {agent_url}")
                    return agent_url
            except Exception as e:
                logger.warning(f"🍃 MongoDB registry lookup failed: {e}")
        
        # Try HTTP registry lookup if available
        if self.registry_url:
            try:
                response = requests.get(f"{self.registry_url}/lookup/{agent_id}", timeout=10)
                if response.status_code == 200:
                    data = response.json()
                    agent_url = data.get("agent_url")
                    logger.info(f"🌐 Found {agent_id} in HTTP registry: {agent_url}")
                    return agent_url
            except Exception as e:
                logger.warning(f"🌐 HTTP registry lookup failed: {e}")
        
        # Fallback to local discovery (for testing)
        local_agents = {
            "test_agent": "http://localhost:6000",
            "pirate_agent": "http://localhost:6001", 
            "helpful_agent": "http://localhost:6002",
            "echo_agent": "http://localhost:6003",
            "simple_test_agent": "http://localhost:6005",
            "agent_alpha": "http://localhost:6010",
            "agent_beta": "http://localhost:6011"
        }
        
        if agent_id in local_agents:
            logger.info(f"🏠 Found {agent_id} locally: {local_agents[agent_id]}")
            return local_agents[agent_id]
        
        logger.warning(f"❌ Agent {agent_id} not found in any registry")
        return None
    
    def _create_response(self, original_msg: Message, conversation_id: str, text: str) -> Message:
        """Create a response message"""
        return Message(
            role=MessageRole.AGENT,
            content=TextContent(text=f"[{self.agent_id}] {text}"),
            parent_message_id=original_msg.message_id,
            conversation_id=conversation_id
        )