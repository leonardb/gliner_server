#!/usr/bin/env python3
"""Debug script to test state codes extraction."""

import socket
import json
import struct
import time

def send_request(text):
    """Send analyze request and get response."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect(('localhost', 9000))
        
        # Prepare request
        req_data = json.dumps({
            "id": "test_1",
            "method": "analyze",
            "params": {
                "text": text,
                "return_type": "map"
            }
        }).encode('utf-8')
        
        # Send request with port protocol
        msg = struct.pack('>H', len(req_data)) + req_data
        sock.sendall(msg)
        
        # Receive response
        header = sock.recv(2)
        if header:
            size = struct.unpack('>H', header)[0]
            response_data = b''
            while len(response_data) < size:
                chunk = sock.recv(size - len(response_data))
                if not chunk:
                    break
                response_data += chunk
            
            response = json.loads(response_data.decode('utf-8'))
            return response
    finally:
        sock.close()

if __name__ == '__main__':
    import sys
    import subprocess
    import os
    
    # Start the server if not running
    print("Starting GLiNER server...")
    server_proc = subprocess.Popen(
        ['/opt/native_gliner_worker/_build/default/lib/gliner_server/ebin/gliner_server'],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    # Wait for server to start
    time.sleep(5)
    
    try:
        # Test cases from the test suite
        test_cases = [
            ("I live in Arizona", 1),
            ("I live in AZ", 1),
            ("I live in AZ.", 1),
            ("I live in AZ, near Phoenix", 1),
            ("Sunny in FL! Come visit", 1),
            ("Is it in NY? Yes it is", 1),
            ("Here in CA: the best state", 1),
            ("Born in TX, raised in FL, live in CA", 3),
            ("AZAZ", 0),
            ("AZ Arizona AZ", 3)
        ]
        
        for text, expected in test_cases:
            try:
                response = send_request(text)
                entities = response.get('result', {}).get('entities', [])
                state_entities = [e for e in entities if e.get('entity_type') == 'location_state']
                actual = len(state_entities)
                status = "✓" if actual == expected else "✗"
                print(f"{status} '{text}': expected {expected}, got {actual}")
                if actual != expected:
                    print(f"   Entities: {state_entities}")
            except Exception as e:
                print(f"✗ Error testing '{text}': {e}")
    finally:
        server_proc.terminate()
        server_proc.wait()
