import base64
import contextlib
import io
import json
import os
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import daytape_bridge


class BridgeClientTests(unittest.TestCase):
    def server(self, wrong_identity=False, corrupt=False):
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(1)
        key = bytes(range(32)); pairing = {"host": "127.0.0.1", "port": listener.getsockname()[1], "key": base64.b64encode(key).decode()}
        observed = []
        def run():
            try:
                with listener.accept()[0] as connection:
                    size = struct.unpack(">I", daytape_bridge.receive_exact(connection, 4))[0]
                    frame = daytape_bridge.receive_exact(connection, size)
                    request = json.loads(AESGCM(key).decrypt(frame[:12], frame[12:], None)); observed.append(request)
                    response = json.dumps({"id": "wrong" if wrong_identity else request["id"], "timestamp": time.time(), "result": [{"text": "今天的原话"}]}).encode()
                    nonce = os.urandom(12); sealed = nonce + AESGCM(key).encrypt(nonce, response, None)
                    if corrupt: sealed = sealed[:-1] + bytes([sealed[-1] ^ 1])
                    # Deliberately fragmented frames exercise exact reads.
                    frame = struct.pack(">I", len(sealed)) + sealed
                    connection.sendall(frame[:2]); connection.sendall(frame[2:9]); connection.sendall(frame[9:])
            finally: listener.close()
        worker = threading.Thread(target=run); worker.start()
        return pairing, observed, worker

    def test_real_encrypted_request_and_fragmented_response(self):
        pairing, observed, worker = self.server()
        self.assertEqual(daytape_bridge.read_phone(pairing, "search", query="原话"), [{"text": "今天的原话"}])
        worker.join(2)
        self.assertEqual(observed[0]["command"], "search"); self.assertEqual(observed[0]["query"], "原话")

    def test_response_identity_and_authenticated_ciphertext_are_checked(self):
        for options in ({"wrong_identity": True}, {"corrupt": True}):
            pairing, _, worker = self.server(**options)
            with self.assertRaises(Exception): daytape_bridge.read_phone(pairing, "status")
            worker.join(2)

    def test_mcp_lists_only_readonly_tools_and_routes_search(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "daytape_search", "arguments": {"query": "会议"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "delete_everything", "arguments": {}}},
        ]
        output = io.StringIO()
        with patch("sys.stdin", io.StringIO("\n".join(map(json.dumps, messages)))), contextlib.redirect_stdout(output), patch.object(daytape_bridge, "read_phone", return_value=[]) as call:
            daytape_bridge.run_mcp({})
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses[1]["result"]["tools"]), 5)
        call.assert_called_once_with({}, "search", query="会议")
        self.assertIn("error", responses[-1])


if __name__ == "__main__": unittest.main()
