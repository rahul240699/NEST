#!/usr/bin/env python3
"""
Payment middleware for NANDA agents.

This module handles payment flows between agents:
1. Checks if target agent requires payment (serviceCharge > 0)
2. Returns 402 Payment Required with amount if needed
3. Processes payments via nanda-payments MCP server
4. Validates receipts before processing requests
"""

import asyncio
import logging
import time
import json
from typing import Optional, Dict, Any, Tuple
from dataclasses import dataclass
from enum import Enum

# MCP support imports
try:
    from ..core.mcp_client import MCPClient
    MCP_AVAILABLE = True
except ImportError:
    MCP_AVAILABLE = False

# NEST adapter imports
try:
    from ..core.abstract_registry_client import AbstractRegistryClient
    REGISTRY_AVAILABLE = True
except ImportError:
    REGISTRY_AVAILABLE = False

logger = logging.getLogger(__name__)


class PaymentStatus(Enum):
    """Payment status enum"""
    NOT_REQUIRED = "not_required"
    REQUIRED = "required" 
    PAID = "paid"
    INVALID_RECEIPT = "invalid_receipt"
    INSUFFICIENT_BALANCE = "insufficient_balance"
    PAYMENT_FAILED = "payment_failed"


@dataclass
class PaymentResult:
    """Result of payment check/processing"""
    status: PaymentStatus
    amount: int = 0
    receipt_id: Optional[str] = None
    message: str = ""
    transaction_id: Optional[str] = None


class PaymentMiddleware:
    """
    Middleware for handling agent-to-agent payment flows.
    
    Handles the complete payment lifecycle:
    1. Check if payment required
    2. Process payment via MCP
    3. Validate receipts
    4. Return appropriate responses
    """
    
    def __init__(self, registry_client: Optional[AbstractRegistryClient] = None, mcp_registry=None):
        """
        Initialize payment middleware.
        
        Args:
            registry_client: NEST AbstractRegistryClient for agent lookup
            mcp_registry: MCP registry for payment server access
        """
        self.registry_client = registry_client
        self.mcp_registry = mcp_registry
        
    def check_payment_requirement(self, target_agent_id: str) -> PaymentResult:
        """
        Check if target agent requires payment.
        
        Args:
            target_agent_id: ID of the agent being contacted
            
        Returns:
            PaymentResult indicating if payment is required
        """
        if not self.registry_client:
            return PaymentResult(
                status=PaymentStatus.NOT_REQUIRED,
                message="Registry client not available"
            )
        
        # Get target agent info from NEST registry
        agent_info = self.registry_client.lookup_agent(target_agent_id)
        
        if not agent_info:
            return PaymentResult(
                status=PaymentStatus.NOT_REQUIRED,
                message=f"Agent {target_agent_id} not found"
            )
        
        service_charge = agent_info.get("service_charge", 0)
        
        if service_charge <= 0:
            return PaymentResult(
                status=PaymentStatus.NOT_REQUIRED,
                message=f"Agent {target_agent_id} is free"
            )
        
        return PaymentResult(
            status=PaymentStatus.REQUIRED,
            amount=service_charge,
            message=f"Agent {target_agent_id} requires {service_charge} NP per request"
        )
    
    async def ensure_agent_wallet(self, agent_name: str) -> bool:
        """Ensure agent has a wallet attached"""
        try:
            client = MCPClient()
            tools = await client.connect_to_server("https://p01--nanda-points-mcp--qvf8hqwjtv29.code.run/mcp")
            if not tools:
                return False
            
            # Check if agent already has a balance (wallet attached)
            try:
                result = await client.session.call_tool("getBalance", {"agent_name": agent_name})
                # If successful, agent has wallet
                await client.exit_stack.aclose()
                return True
            except:
                # Agent doesn't have wallet, attach one - just send agent ID
                try:
                    await client.session.call_tool("attachWallet", {
                        "agent_id": agent_name
                    })
                    await client.exit_stack.aclose()
                    return True
                except Exception as e:
                    print(f"Failed to attach wallet for {agent_name}: {e}")
                    await client.exit_stack.aclose()
                    return False
        except Exception as e:
            print(f"Error ensuring wallet for {agent_name}: {e}")
            return False

    def process_payment_sync(self, source_agent_id: str, target_agent_id: str, amount: int) -> PaymentResult:
        """
        Synchronous wrapper for payment processing - keeps agent bridge code simple
        """
        import asyncio
        import threading
        
        def run_async_payment():
            # Create new event loop for this thread
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                return loop.run_until_complete(
                    self.process_payment(source_agent_id, target_agent_id, amount)
                )
            finally:
                loop.close()
        
        # Run in separate thread to avoid event loop conflicts
        result_container = {}
        def thread_target():
            result_container['result'] = run_async_payment()
        
        thread = threading.Thread(target=thread_target)
        thread.start()
        thread.join()
        
        return result_container.get('result', PaymentResult(
            status=PaymentStatus.PAYMENT_FAILED,
            message="Payment processing failed"
        ))

    def validate_receipt_sync(self, receipt_id: str) -> PaymentResult:
        """
        Synchronous wrapper for receipt validation - keeps agent bridge code simple
        """
        import asyncio
        import threading
        
        def run_async_validation():
            # Create new event loop for this thread
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                return loop.run_until_complete(
                    self.validate_receipt(receipt_id)
                )
            finally:
                loop.close()
        
        # Run in separate thread to avoid event loop conflicts
        result_container = {}
        def thread_target():
            result_container['result'] = run_async_validation()
        
        thread = threading.Thread(target=thread_target)
        thread.start()
        thread.join()
        
        return result_container.get('result', PaymentResult(
            status=PaymentStatus.INVALID_RECEIPT,
            message="Receipt validation failed"
        ))

    async def process_payment(
        self, 
        source_agent_id: str, 
        target_agent_id: str, 
        amount: int,
        mcp_server_url: str = "https://p01--nanda-points-mcp--qvf8hqwjtv29.code.run/mcp",
        anthropic_client=None
    ) -> PaymentResult:
        """
        Process payment from source to target agent.
        
        Args:
            source_agent_id: Agent making the payment
            target_agent_id: Agent receiving the payment  
            amount: Amount in Neural Points
            mcp_server_url: nanda-payments MCP server URL
            
        Returns:
            PaymentResult with transaction details
        """
        if not MCP_AVAILABLE:
            return PaymentResult(
                status=PaymentStatus.PAYMENT_FAILED,
                message="MCP support not available"
            )
        
        try:
            # Let MCP server handle wallet management automatically
            if not await self.ensure_agent_wallet(source_agent_id):
                return PaymentResult(
                    status=PaymentStatus.PAYMENT_FAILED,
                    message=f"Failed to setup wallet for sender: {source_agent_id}"
                )
            
            if not await self.ensure_agent_wallet(target_agent_id):
                return PaymentResult(
                    status=PaymentStatus.PAYMENT_FAILED,
                    message=f"Failed to setup wallet for recipient: {target_agent_id}"
                )
            
            client = MCPClient()
            
            # Connect to the MCP server
            tools = await client.connect_to_server(mcp_server_url)
            if not tools:
                return PaymentResult(
                    status=PaymentStatus.PAYMENT_FAILED,
                    message="Could not connect to MCP payment server"
                )
            
            # Use the initiateTransaction tool directly
            task_description = f"Agent-to-agent service request from {source_agent_id} to {target_agent_id}"
            
            # Call the initiateTransaction tool directly
            transaction_result = await client.session.call_tool(
                "initiateTransaction",
                {
                    "from": source_agent_id,
                    "to": target_agent_id, 
                    "amount": amount,
                    "task": task_description
                }
            )
            
            # Parse the MCP response properly
            if transaction_result and transaction_result.content:
                response_text = transaction_result.content[0].text
                try:
                    response_data = json.loads(response_text)
                    
                    if "transaction_id" in response_data:
                        transaction_id = response_data["transaction_id"]
                        return PaymentResult(
                            status=PaymentStatus.PAID,
                            amount=amount,
                            receipt_id=transaction_id,
                            transaction_id=transaction_id,
                            message=f"Payment of {amount} NP processed successfully"
                        )
                    elif "error" in response_data:
                        error = response_data["error"]
                        if error == "INSUFFICIENT_BALANCE":
                            return PaymentResult(
                                status=PaymentStatus.INSUFFICIENT_BALANCE,
                                message=f"Insufficient balance for {amount} NP payment"
                            )
                        else:
                            return PaymentResult(
                                status=PaymentStatus.PAYMENT_FAILED,
                                message=f"Payment failed: {error}"
                            )
                except json.JSONDecodeError:
                    # Fallback to string parsing for non-JSON responses
                    result = str(transaction_result)
                    if "completed successfully" in result.lower():
                        return PaymentResult(
                            status=PaymentStatus.PAID,
                            amount=amount,
                            message=f"Payment of {amount} NP processed successfully"
                        )
                    elif "insufficient" in result.lower():
                        return PaymentResult(
                            status=PaymentStatus.INSUFFICIENT_BALANCE,
                            message=f"Insufficient balance for {amount} NP payment"
                        )
                    else:
                        return PaymentResult(
                            status=PaymentStatus.PAYMENT_FAILED,
                            message=f"Payment failed: {result}"
                        )
            
            return PaymentResult(
                status=PaymentStatus.PAYMENT_FAILED,
                message="No response from payment server"
            )
                    
        except Exception as e:
            return PaymentResult(
                status=PaymentStatus.PAYMENT_FAILED,
                message=f"Payment processing error: {str(e)}"
            )
    
    async def validate_receipt(
        self, 
        receipt_id: str,
        mcp_server_url: str = "https://p01--nanda-points-mcp--qvf8hqwjtv29.code.run/mcp",
        anthropic_client=None
    ) -> PaymentResult:
        """
        Validate a payment receipt.
        
        Args:
            receipt_id: Receipt ID to validate
            mcp_server_url: nanda-payments MCP server URL
            
        Returns:
            PaymentResult with validation status
        """
        if not MCP_AVAILABLE:
            return PaymentResult(
                status=PaymentStatus.INVALID_RECEIPT,
                message="MCP support not available"
            )
        
        try:
            client = MCPClient()
            
            # Connect to the MCP server
            tools = await client.connect_to_server(mcp_server_url)
            if not tools:
                return PaymentResult(
                    status=PaymentStatus.INVALID_RECEIPT,
                    message="Could not connect to MCP payment server"
                )
            
            # Use the getReceipt tool directly
            receipt_result = await client.session.call_tool(
                "getReceipt",
                {"txId": receipt_id}
            )
            
            # Parse the MCP response properly
            if receipt_result and receipt_result.content:
                response_text = receipt_result.content[0].text
                try:
                    response_data = json.loads(response_text)
                    
                    if "error" in response_data:
                        return PaymentResult(
                            status=PaymentStatus.INVALID_RECEIPT,
                            message=f"Receipt {receipt_id} not found or invalid"
                        )
                    elif "transaction_id" in response_data or "amount" in response_data:
                        amount = response_data.get("amount", 0)
                        return PaymentResult(
                            status=PaymentStatus.PAID,
                            amount=amount,
                            receipt_id=receipt_id,
                            message=f"Receipt {receipt_id} validated for {amount} NP"
                        )
                except json.JSONDecodeError:
                    # Fallback to string parsing
                    result = str(receipt_result)
                    if "not found" in result.lower() or "invalid" in result.lower():
                        return PaymentResult(
                            status=PaymentStatus.INVALID_RECEIPT,
                            message=f"Receipt {receipt_id} not found or invalid"
                        )
                    else:
                        # Extract amount from receipt
                        import re
                        amount_match = re.search(r'(\d+)\s*NP', result)
                        amount = int(amount_match.group(1)) if amount_match else 0
                        
                        return PaymentResult(
                            status=PaymentStatus.PAID,
                            amount=amount,
                            receipt_id=receipt_id,
                            message=f"Receipt {receipt_id} validated for {amount} NP"
                        )
            
            return PaymentResult(
                status=PaymentStatus.INVALID_RECEIPT,
                message="No response from payment server"
            )
                
        except Exception as e:
            return PaymentResult(
                status=PaymentStatus.INVALID_RECEIPT,
                message=f"Receipt validation error: {str(e)}"
            )
    
    def format_payment_required_response(self, payment_result: PaymentResult, target_agent_id: str) -> str:
        """
        Format 402 Payment Required response.
        
        Args:
            payment_result: Payment result with amount required
            target_agent_id: Target agent ID
            
        Returns:
            Formatted payment required message
        """
        return f"402-PAYMENT-REQUIRED: Agent '{target_agent_id}' requires {payment_result.amount} NP per request. Please include payment receipt in your message."
    
    def format_payment_success_response(self, payment_result: PaymentResult) -> str:
        """
        Format successful payment response.
        
        Args:
            payment_result: Payment result with transaction details
            
        Returns:
            Formatted success message
        """
        return f"✅ Payment processed: {payment_result.message}. Receipt ID: {payment_result.receipt_id}"
    
    def extract_receipt_from_message(self, message: str) -> Optional[str]:
        """
        Extract receipt ID from message.
        
        Args:
            message: Message that might contain receipt ID
            
        Returns:
            Receipt ID if found, None otherwise
        """
        import re
        
        # Look for receipt patterns
        patterns = [
            r'receipt[_\s]?id[:\s]+([a-zA-Z0-9\-]+)',
            r'receipt[:\s]+([a-zA-Z0-9\-]+)',
            r'payment[_\s]?receipt[:\s]+([a-zA-Z0-9\-]+)',
            r'#receipt[:\s]*([a-zA-Z0-9\-]+)',
        ]
        
        for pattern in patterns:
            match = re.search(pattern, message, re.IGNORECASE)
            if match:
                return match.group(1)
        
        return None


# Helper function to create payment middleware
def create_payment_middleware(registry_client: Optional[AbstractRegistryClient] = None, mcp_registry=None):
    """
    Create payment middleware instance.
    
    Args:
        registry_client: NEST AbstractRegistryClient instance
        mcp_registry: MCP registry (optional)
        
    Returns:
        PaymentMiddleware instance
    """
    return PaymentMiddleware(registry_client, mcp_registry)