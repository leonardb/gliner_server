#!/usr/bin/env python3
"""Test script to debug state code extraction."""

import subprocess
import json
import sys

def test_rust_extraction():
    """Call the Rust binary directly with test input."""
    # Create a simple test request
    test_text = "I live in AZ"
    
    # The binary expects protocol format
    # For testing, we'd need to set up the full protocol
    # But let's check if we can just run the binary and see what happens
    
    print(f"Testing Rust extraction with: '{test_text}'")
    
    # We can't easily test this without starting the full server
    # Let's instead check if the test passes by examining the output
    
if __name__ == '__main__':
    # Try to extract from the HTML log what the Rust code is actually returning
    import re
    import glob
    
    for html_file in glob.glob('/opt/native_gliner_worker/_build/test/logs/**/gliner_SUITE.logs.html', recursive=True):
        print(f"Checking {html_file}")
        with open(html_file) as f:
            content = f.read()
            
            # Look for "All entities" entries
            entity_matches = re.findall(r'All entities: (.*?)<', content)
            for i, entities_str in enumerate(entity_matches):
                print(f"\nEntities block {i}: {entities_str[:200]}")
