#!/bin/bash
# System dependency checker for GLiNER Worker build
# This script verifies that all required libraries and build tools are installed
# before attempting to compile the Rust binary with ONNX Runtime

set -e

echo "=== GLiNER Worker Build Dependency Checker ==="
echo

# Track missing dependencies
MISSING_TOOLS=()
MISSING_LIBS=()
WARNINGS=()

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
check_command() {
    local cmd=$1
    local name=$2
    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $name: $(command -v $cmd)"
        return 0
    else
        echo -e "${RED}✗${NC} $name: NOT FOUND"
        MISSING_TOOLS+=("$name")
        return 1
    fi
}

check_library() {
    local lib=$1
    local name=$2
    if ldconfig -p | grep -q "$lib"; then
        LIBPATH=$(ldconfig -p | grep "$lib" | head -1 | awk '{print $NF}')
        echo -e "${GREEN}✓${NC} $name: $LIBPATH"
        return 0
    else
        echo -e "${RED}✗${NC} $name: NOT FOUND"
        MISSING_LIBS+=("$name")
        return 1
    fi
}

check_file() {
    local path=$1
    local name=$2
    if [ -e "$path" ] 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $name: found"
        return 0
    else
        echo -e "${RED}✗${NC} $name: NOT FOUND"
        MISSING_LIBS+=("$name")
        return 1
    fi
}

# System detection
echo "[*] System Detection"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo -e "${GREEN}✓${NC} Detected Linux"
    OS_TYPE="linux"
    # Try to identify distro
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "    Distribution: $PRETTY_NAME"
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "${GREEN}✓${NC} Detected macOS"
    OS_TYPE="macos"
else
    echo -e "${RED}✗${NC} Unsupported OS: $OSTYPE"
    exit 1
fi
echo

# Check build tools
echo "[1] Build Tools"
check_command "rustc" "Rust compiler" || true
check_command "cargo" "Cargo package manager" || true
check_command "gcc" "GCC C compiler" || true
check_command "g++" "GCC C++ compiler" || true
check_command "pkg-config" "pkg-config" || true
echo

# Check system libraries
echo "[2] System Libraries"
check_library "libstdc++" "C++ Standard Library (libstdc++)" || true
check_library "libc.so" "C Library (glibc)" || true
check_library "libgcc_s" "GCC Support Library (libgcc_s)" || true
check_library "libm.so" "Math Library (libm)" || true
check_library "libpthread" "POSIX Threads Library (libpthread)" || true
check_library "libdl.so" "Dynamic Linker Library (libdl)" || true
echo

# Check development headers (Linux)
if [ "$OS_TYPE" = "linux" ]; then
    echo "[3] Development Headers"
    check_file "/usr/include/stdlib.h" "C Standard Headers" || true
    if [ -d "/usr/include/c++" ]; then
        echo -e "${GREEN}✓${NC} C++ Standard Headers: /usr/include/c++"
    else
        echo -e "${RED}✗${NC} C++ Standard Headers: NOT FOUND"
        MISSING_LIBS+=("C++ Standard Headers")
    fi
    echo
fi

# OpenSSL check (needed for some dependencies)
echo "[4] Optional Libraries"
if command -v openssl &> /dev/null; then
    echo -e "${GREEN}✓${NC} OpenSSL: $(openssl version)"
else
    echo -e "${YELLOW}⚠${NC} OpenSSL: NOT FOUND (needed for HTTPS dependencies)"
    WARNINGS+=("OpenSSL")
fi
echo

# Summary
echo "[=] Summary"
if [ ${#MISSING_TOOLS[@]} -eq 0 ] && [ ${#MISSING_LIBS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All required dependencies are installed!${NC}"
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠ Warnings:${NC}"
        for warning in "${WARNINGS[@]}"; do
            echo "  - $warning is not installed (optional, may be needed)"
        done
    fi
    exit 0
else
    echo -e "${RED}✗ Missing dependencies detected:${NC}"
    if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
        echo -e "${RED}  Build Tools:${NC}"
        for tool in "${MISSING_TOOLS[@]}"; do
            echo "    - $tool"
        done
    fi
    if [ ${#MISSING_LIBS[@]} -gt 0 ]; then
        echo -e "${RED}  Libraries:${NC}"
        for lib in "${MISSING_LIBS[@]}"; do
            echo "    - $lib"
        done
    fi
    echo
    
    # Installation instructions
    echo "[!] Installation Instructions"
    if [ "$OS_TYPE" = "linux" ]; then
        if grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
            echo "Debian/Ubuntu:"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install -y build-essential pkg-config libssl-dev"
        elif grep -qi "centos\|rhel\|fedora" /etc/os-release 2>/dev/null; then
            echo "CentOS/RHEL/Fedora:"
            echo "  sudo yum groupinstall -y 'Development Tools'"
            echo "  sudo yum install -y gcc-c++ pkg-config openssl-devel"
        fi
    elif [ "$OS_TYPE" = "macos" ]; then
        echo "macOS (using Homebrew):"
        echo "  brew install rustup pkg-config openssl"
        echo "  rustup-init"
    fi
    echo
    exit 1
fi

