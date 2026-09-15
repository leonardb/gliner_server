#!/usr/bin/env python3
"""Debug script to check state code extraction in Erlang server."""

import socket
import json
import sys
import struct

def send_analyze_request(text, return_type="map"):
    """Send analyze request to gliner_server via TCP."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect(('localhost', 8888))
        
        # Format: {analyze, Text, ReturnType}
        request = {
            "analyze": text,
            "return_type": return_type
        }
        
        request_json = json.dumps(request).encode('utf-8')
        sock.sendall(request_json + b'\n')
        
        # Read response
        response_data = b''
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_data += chunk
            if b'\n' in response_data:
                break
        
        response = json.loads(response_data.decode('utf-8'))
        return response
        
    finally:
        sock.close()

def main():
    test_cases = [
        "I live in AZ",
        "AZ is nice",
        "Arizona and AZ",
        "AZAZ",
        "I live in AZ.",
    ]
    
    for text in test_cases:
        try:
            response = send_analyze_request(text)
            entities = response.get('entities', [])
            
            # Filter for state entities
            state_entities = [e for e in entities if e.get('entity_type') == 'state']
            
            print(f"\nText: '{text}'")
            print(f"  Found {len(state_entities)} state codes")
            for entity in state_entities:
                print(f"    - {entity.get('text')} (score: {entity.get('score')})")
        except Exception as e:
            print(f"Text: '{text}'")
            print(f"  Error: {e}")

if __name__ == '__main__':
    main()
