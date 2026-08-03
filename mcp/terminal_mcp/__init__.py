"""COMSTAR terminal MCP package (stdio + mcp-proxy)."""

from .server import TOOLS, handle_tool, main

__all__ = ["TOOLS", "handle_tool", "main"]
