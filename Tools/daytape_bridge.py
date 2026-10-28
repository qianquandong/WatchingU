#!/usr/bin/env python3
"""Read-only encrypted DayTape client and stdio MCP server. Requires cryptography."""
import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
import uuid
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def receive_exact(connection, count):
    chunks = bytearray()
    while len(chunks) < count:
        chunk = connection.recv(count - len(chunks))
        if not chunk:
            raise RuntimeError("Phone closed the connection; check scope, foreground state and pairing configuration.")
        chunks.extend(chunk)
    return bytes(chunks)


def read_phone(pairing, command, **arguments):
    key = base64.b64decode(pairing["key"], validate=True)
    if len(key) != 32:
        raise ValueError("Pairing key must contain 32 bytes")
    identity = str(uuid.uuid4())
    request = {"id": identity, "timestamp": time.time(), "command": command, **arguments}
    nonce = os.urandom(12)
    encrypted = nonce + AESGCM(key).encrypt(nonce, json.dumps(request, ensure_ascii=False).encode(), None)
    with socket.create_connection((pairing["host"], int(pairing["port"])), timeout=15) as connection:
        connection.sendall(struct.pack(">I", len(encrypted)) + encrypted)
        length = struct.unpack(">I", receive_exact(connection, 4))[0]
        if not 28 <= length <= 5 * 1024 * 1024:
            raise ValueError("Invalid response length")
        data = receive_exact(connection, length)
    response = json.loads(AESGCM(key).decrypt(data[:12], data[12:], None))
    if response.get("id") != identity or abs(response.get("timestamp", 0) - time.time()) >= 120:
        raise ValueError("Response identity or timestamp mismatch")
    return response["result"]


TOOLS = [
    {"name": "daytape_search", "description": "Search transcripts in the iPhone owner's explicitly selected date range.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"], "additionalProperties": False}},
    {"name": "daytape_read_day", "description": "Read saved transcripts for a YYYY-MM-DD day within the selected scope.",
     "inputSchema": {"type": "object", "properties": {"day": {"type": "string"}}, "required": ["day"], "additionalProperties": False}},
    {"name": "daytape_reviews", "description": "Read saved reviews with source citations; does not generate new AI requests.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "daytape_memories", "description": "Read active saved memories whose sources are inside the selected scope.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "daytape_audio", "description": "Read original audio only if the iPhone owner enabled audio access for this scope.",
     "inputSchema": {"type": "object", "properties": {"clipID": {"type": "string"}}, "required": ["clipID"], "additionalProperties": False}},
]


def run_mcp(pairing):
    commands = {"daytape_search": "search", "daytape_read_day": "day", "daytape_reviews": "reviews", "daytape_memories": "memories", "daytape_audio": "audio"}
    for line in sys.stdin:
        message = None
        try:
            message = json.loads(line)
            if "id" not in message:
                continue
            method = message.get("method")
            if method == "initialize":
                result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "daytape-readonly", "version": "0.5.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = message.get("params", {})
                name = params.get("name")
                if name not in commands:
                    raise ValueError("Unknown read-only tool")
                value = read_phone(pairing, commands[name], **params.get("arguments", {}))
                result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Method not found"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}, ensure_ascii=False), flush=True)
        except Exception as error:
            if isinstance(message, dict) and "id" in message:
                print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": str(error)}}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairing", required=True, type=Path, help="JSON configuration copied from the phone. Keep this local and private.")
    parser.add_argument("--stdio", action="store_true", help="Run as an MCP stdio server")
    parser.add_argument("command", nargs="?", choices=["status", "search", "day", "reviews", "memories", "audio"], default="status")
    parser.add_argument("--query")
    parser.add_argument("--day")
    parser.add_argument("--clip-id")
    options = parser.parse_args()
    pairing = json.loads(options.pairing.read_text(encoding="utf-8"))
    if options.stdio:
        run_mcp(pairing)
    else:
        arguments = {key: value for key, value in {"query": options.query, "day": options.day, "clipID": options.clip_id}.items() if value is not None}
        print(json.dumps(read_phone(pairing, options.command, **arguments), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
