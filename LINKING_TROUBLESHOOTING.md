# C++ Linking Configuration for ONNX Runtime

## Quick Start: Checking Build Prerequisites

Before building, verify that all required dependencies are installed:

```bash
bash build-with-libs.sh
```

This script will:
- ✓ Detect your system (Linux/macOS)
- ✓ Check for required build tools (rustc, cargo, gcc, g++, pkg-config)
- ✓ Check for required system libraries (libstdc++, glibc, etc.)
- ✓ Check for development headers
- ✓ Provide installation instructions if anything is missing

Example output:
```
=== GLiNER Worker Build Dependency Checker ===

[1] Build Tools
✓ Rust compiler: /usr/bin/rustc
✓ Cargo package manager: /usr/bin/cargo
✓ GCC C compiler: /usr/bin/gcc
✓ GCC C++ compiler: /usr/bin/g++

[2] System Libraries
✓ C++ Standard Library (libstdc++)
✓ C Library (glibc)
✓ GCC Support Library (libgcc_s)
✓ Math Library (libm)

[=] Summary
✓ All required dependencies are installed!
```

If dependencies are missing, the script provides installation instructions for your system.

## How It Works Internally

### The Three-Layer Solution

#### 1. Dependency Checker Script (`build-with-libs.sh`)

Pre-build verification tool that validates all required dependencies:
- Build tools: rustc, cargo, gcc, g++, pkg-config
- System libraries: libstdc++, glibc, libgcc_s, libm, libpthread, libdl
- Development headers: C and C++ standard headers
- Optional libraries: OpenSSL

Provides detailed diagnostics and installation instructions for missing dependencies.

**Usage:** `bash build-with-libs.sh` before attempting to build

#### 2. Cargo Configuration (`.cargo/config.toml`)

Explicitly specifies all required system libraries:

```toml
[build]
rustflags = [
    "-C", "link-arg=-lc",           # C library (essential)
    "-C", "link-arg=-lstdc++",      # C++ standard library
    "-C", "link-arg=-lgcc_s",       # GCC support library (unwinding)
    "-C", "link-arg=-lm",           # Math library
    "-C", "link-arg=-ldl",          # Dynamic linker
    "-C", "link-arg=-lpthread",     # POSIX threads
    "-C", "link-arg=-Wl,--as-needed",
    "-C", "link-arg=-Wl,-rpath=/usr/lib/x86_64-linux-gnu",
    "-C", "link-arg=-Wl,-rpath=/usr/lib64",
]
```

#### 3. rebar.config Integration

The Erlang build system handles Rust compilation:

```erlang
{pre_hooks,
 [{"(linux|darwin|win32)", compile, 
   "bash -c 'cd native_gliner_worker && cargo build --release'"}]}.
```

The `.cargo/config.toml` in the native_gliner_worker directory ensures all required libraries are linked during compilation.

## Troubleshooting

### Step 1: Verify Dependencies Are Installed

Run the dependency checker before building:

```bash
bash build-with-libs.sh
```

This will:
- Check all required build tools
- Check all required system libraries
- Verify development headers are present
- Provide installation commands if anything is missing

### Step 2: Install Missing Dependencies

If the checker reports missing dependencies, follow its installation instructions.

**Debian/Ubuntu:**
```bash
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libssl-dev
```

**CentOS/RHEL/Fedora:**
```bash
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y gcc-c++ pkg-config openssl-devel
```

**macOS (with Homebrew):**
```bash
brew install rustup pkg-config openssl
rustup-init
```

### Step 3: Build the Project

Once all dependencies are installed, build normally:

```bash
make build        # For standalone build
rebar3 compile    # For dependency build
```

The `.cargo/config.toml` configuration handles all C++ linking automatically.

### Advanced Troubleshooting

#### libstdc++ Version Mismatch

If you see undefined C++ symbols after dependencies are installed, there may be a version mismatch:

```bash
# Check what versions are available
ldconfig -p | grep libstdc++

# Check version used by g++
g++ -print-file-name=libstdc++.so.6

# Check the GLIBCXX version
strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 | grep GLIBCXX | tail -1
```

The ONNX Runtime precompiled libraries may require a specific libstdc++ version. Ensure your system has a compatible version installed.

#### Alternative C++ Standard Library

If libstdc++ linking continues to fail, try linking with libc++ instead:

Edit `.cargo/config.toml`:
```toml
[build]
rustflags = [
    "-C", "link-arg=-lc++",     # Use libc++ instead of libstdc++
    "-C", "link-arg=-lm",
    "-C", "link-arg=-lc",
    "-C", "link-arg=-ldl",
    "-C", "link-arg=-lpthread",
]
```

Then rebuild:
```bash
cd native_gliner_worker && cargo clean && cargo build --release
```

#### Static Linking

For environments where shared libraries are problematic:

```toml
[build]
rustflags = [
    "-C", "target-feature=+crt-static",
    "-C", "link-arg=-static-libstdc++",
]
```

## Linking Errors: Dependency Context & GCC Version Mismatches

### Symptom 1: Errors When Building as a Dependency

If you see C++ linker errors when this project is built as a dependency of another Erlang application:

**Symptoms:**
- `undefined symbol: std::__throw_bad_array_new_length()`
- `undefined symbol: __libc_single_threaded`
- `undefined symbol: std::__cxx11::basic_string<...>::reserve()`
- Linker command shows `-fuse-ld=lld` (using LLVM linker instead of GNU ld)
- Build path contains parent application directory: `/opt/exapi/_build/default/lib/gliner_server/native_gliner_worker/...`

**Root Cause:**
1. The build directory structure differs from standalone builds
2. Cargo's working directory changes
3. The linker may use LLVM's lld instead of GNU ld
4. **Library linking order becomes critical**: C++ libraries must be linked BEFORE the C library
5. The `-Wl,--as-needed` flag can prematurely strip C++ ABI symbols

### Symptom 2: GCC 9.x Compatibility Issues

If your system has **only GCC 9.x** (or defaults to GCC 9):

**Symptoms:**
- Same C++ ABI symbol errors as above
- `gcc --version` shows: `gcc (Ubuntu 9.x.x) 9.x.x`
- Build succeeds on systems with GCC 11+ but fails on GCC 9.x systems

**Root Cause - Critical ABI Mismatch:**
- ONNX Runtime precompiled binaries are built with **GCC 11+** (modern C++ ABI)
- GCC 9 uses **older C++ ABI** (GLIBCXX 3.4.9 vs 3.4.35)
- System libstdc++.so.6 has modern ABI symbols, but GCC 9 toolchain expects old ABI
- Linker cannot match C++ symbols between GCC 9's expectations and GCC 11+'s reality

**Solution: Use GNU ld with Runtime Symbol Resolution**

This is already configured in `.cargo/config.toml`:
```toml
rustflags = [
    "-C", "link-arg=-fuse-ld=bfd",                    # Use GNU ld instead of lld
    "-C", "link-arg=-Wl,--allow-shlib-undefined",     # Let runtime linker resolve symbols
    "-C", "link-arg=-Wl,--no-as-needed",              # Protect critical libraries
    "-C", "link-arg=-lstdc++",                        # C++ library FIRST
    # ... other libraries ...
    "-C", "link-arg=-lc",                             # C library LAST
]
```

**How This Fixes GCC 9 Issues:**
1. `-fuse-ld=bfd`: Switches from LLVM's lld to GNU's BFD linker
   - BFD linker understands C++ symbol versioning better
   - More compatible with older GCC toolchains
2. `--allow-shlib-undefined`: Defers symbol resolution to runtime
   - Lets the dynamic linker find C++ ABI symbols at runtime
   - System libstdc++.so.6 has these symbols, even if GCC 9 doesn't
   - This is the proper way to handle mixed-ABI scenarios

### Fix: Corrected Linking Order

The key fix is in `.cargo/config.toml`:

**Before (WRONG - causes linker errors):**
```toml
rustflags = [
    "-C", "link-arg=-lc",           # C library FIRST ❌
    "-C", "link-arg=-lstdc++",      # C++ library SECOND
    "-C", "link-arg=-Wl,--as-needed",  # Can strip needed symbols
]
```

**After (CORRECT - works in all contexts):**
```toml
rustflags = [
    "-C", "link-arg=-Wl,--no-as-needed",  # Protect symbols
    "-C", "link-arg=-lstdc++",             # C++ library FIRST ✓
    "-C", "link-arg=-lgcc_s",
    "-C", "link-arg=-lm",
    "-C", "link-arg=-ldl",
    "-C", "link-arg=-lpthread",
    "-C", "link-arg=-lc",                  # C library LAST ✓
    "-C", "link-arg=-Wl,--as-needed",      # Re-enable after
    "-C", "link-arg=-Wl,-rpath=/lib/x86_64-linux-gnu",
    "-C", "link-arg=-Wl,-rpath=/lib64",
]
```

This configuration has been applied to your project. Rebuild your parent Erlang application:

```bash
cd /path/to/parent/erlang/app
rebar3 compile
```

### If Errors Persist After Fix

1. **Clean build artifacts:**
   ```bash
   cd /path/to/parent/erlang/app
   rebar3 clean
   rebar3 compile
   ```

2. **Verify libstdc++ is available:**
   ```bash
   ldconfig -p | grep libstdc++
   ```

3. **Check which linker is being used:**
   Add `-v` to see the full linker command:
   ```bash
   cd native_gliner_worker
   RUSTFLAGS="-C link-arg=-v" cargo build --release 2>&1 | grep "^" | head -30
   ```

4. **Force GNU ld instead of lld:**
   If lld continues to cause issues, edit `.cargo/config.toml` and add:
   ```toml
   "-C", "link-arg=-fuse-ld=bfd",  # Use BFD linker instead of lld
   ```
   Or:
   ```toml
   "-C", "link-arg=-fuse-ld=gold", # Use GNU gold linker
   ```

## For CI/CD Pipelines and Docker

### Docker Build Example

```dockerfile
FROM rust:latest

RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev

WORKDIR /app
COPY . .

# Verify dependencies before building
RUN bash build-with-libs.sh

# Build the project
RUN make build
```

### Pre-Build Check in CI

```bash
# Verify all dependencies are installed
bash build-with-libs.sh

# If successful, proceed with build
make build
```

## References

- [ONNX Runtime System Library](https://crates.io/crates/ort-sys)
- [Rust Linker Arguments](https://doc.rust-lang.org/rustc/codegen-options/index.html)
- [Cargo Build Configuration](https://doc.rust-lang.org/cargo/reference/config.html)
- [GCC C++ ABI Compatibility](https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html)
