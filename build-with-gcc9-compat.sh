#!/bin/bash
# GCC 9 Compatibility Build Wrapper
# 
# ONNX Runtime precompiled binaries are built with GCC 11+ and use modern C++ ABI symbols.
# When building on a system with only GCC 9.x, we need to ensure proper C++ library linking.
#
# This script:
# 1. Detects the GCC version
# 2. If GCC 9.x is detected, sets environment variables for better symbol resolution
# 3. Builds the Rust binary with proper linker flags

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== GCC 9 Compatibility Build Wrapper ===${NC}\n"

# Detect GCC version
GCC_VERSION=$(gcc --version | head -1 | awk '{print $NF}')
GCC_MAJOR=$(echo "$GCC_VERSION" | cut -d. -f1)
GCC_MINOR=$(echo "$GCC_VERSION" | cut -d. -f2)

echo "Detected GCC version: $GCC_VERSION (Major: $GCC_MAJOR)"

# Check if we need GCC 9 compatibility
if [ "$GCC_MAJOR" -eq 9 ]; then
    echo -e "${YELLOW}[!] GCC 9.x detected - applying compatibility fixes${NC}\n"
    
    # Check libstdc++ version
    if [ -f /usr/lib/x86_64-linux-gnu/libstdc++.so.6 ]; then
        GLIBCXX_VERSION=$(strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 2>/dev/null | grep "^GLIBCXX_" | tail -1)
        echo -e "${GREEN}✓ System libstdc++ has: $GLIBCXX_VERSION${NC}"
    fi
    
    echo -e "${YELLOW}[!] Applying linker workarounds for ONNX Runtime compatibility...${NC}\n"
    
    # Export flags that help the linker find C++ symbols
    export RUSTFLAGS="-C link-arg=-Wl,--copy-dt-needed-entries -C link-arg=-Wl,--as-needed"
    export LDFLAGS="-Wl,--copy-dt-needed-entries"
    export CXXFLAGS="-Wl,--copy-dt-needed-entries"
    
    # Tell cargo to preserve the linker's symbol resolution behavior
    export CARGO_CFG_UNIX=1
    
    echo -e "${YELLOW}[*] Environment variables set:${NC}"
    echo "    RUSTFLAGS: $RUSTFLAGS"
    echo "    LDFLAGS: $LDFLAGS"
    echo ""
    
elif [ "$GCC_MAJOR" -ge 10 ]; then
    echo -e "${GREEN}✓ GCC 10+ detected - using standard build${NC}\n"
else
    echo -e "${RED}✗ Unsupported GCC version: $GCC_MAJOR${NC}"
    exit 1
fi

# Run cargo build
echo -e "${YELLOW}[*] Building with: cargo build --release${NC}\n"
cd "$(dirname "$0")/native_gliner_worker"
cargo build --release

echo ""
echo -e "${GREEN}✓ Build completed successfully!${NC}"
echo "  Binary: $(pwd)/target/release/native_gliner_worker"
