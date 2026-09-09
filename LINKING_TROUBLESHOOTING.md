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

#### libstdc++ Version Mismatch (Deep Dive)

If you see undefined C++ symbols after following the above steps:

```bash
# Check what versions are available
ldconfig -p | grep libstdc++

# Check version used by g++
g++ -print-file-name=libstdc++.so.6

# Check the GLIBCXX version
strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 | grep GLIBCXX | tail -1

# Compare with what Rust expects
rustc -V && rustc --print=sysroot
```

**If GCC 9 is default but GLIBCXX is modern** (3.4.30+):
- This is actually GOOD - system libstdc++ is compatible
- The `-Wl,--allow-shlib-undefined` flag defers resolution to runtime
- Should work with the `.cargo/config.toml` configuration

**If both GCC 9 AND libstdc++ are old** (GLIBCXX 3.4.9):
- You need newer GCC or libstdc++
- Install: `sudo apt-get install -y libstdc++6` (updates system libstdc++)
- Or upgrade GCC: `sudo apt-get install -y gcc-11 g++-11`

#### Debugging Linker Issues

Enable verbose output to see the exact linker command:

```bash
cd native_gliner_worker
RUSTFLAGS="-C link-arg=-v" cargo build --release 2>&1 | head -100
```

Look for:
- `-fuse-ld=bfd` (should be present)
- `-Wl,--allow-shlib-undefined` (should be present)
- `-Wl,-rpath=/usr/lib/x86_64-linux-gnu` (should be present)
- `-nodefaultlibs` (indicates custom library linking)

#### Static Linking (For Extreme Environments)

If all else fails and you have a complex environment, try static libstdc++:

```toml
[build]
rustflags = [
    "-C", "target-feature=+crt-static",
    "-C", "link-arg=-static-libstdc++",
]
```

**Warning**: This increases binary size significantly and may cause other issues.

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
- When using lld linker (in dependency context): "undefined symbol" errors even with `--allow-shlib-undefined`

**Root Cause - Critical ABI Mismatch:**
- ONNX Runtime precompiled binaries are built with **GCC 11+** (modern C++ ABI)
- GCC 9 uses **older C++ ABI** (GLIBCXX 3.4.9 vs 3.4.35)
- System libstdc++.so.6 has modern ABI symbols, but GCC 9 toolchain expects old ABI
- When using lld linker: lld is stricter than GNU ld and needs explicit symbol deferral

**Solution: Defer Symbol Resolution to Runtime Linker**

This is already configured in `.cargo/config.toml`:
```toml
rustflags = [
    "-C", "link-arg=-Wl,--unresolved-symbols=ignore-in-object-files",  # ← CRITICAL for lld
    "-C", "link-arg=-Wl,--no-as-needed",
    "-C", "link-arg=-lstdc++",                      # C++ library FIRST
    "-C", "link-arg=-lstdc++fs",                    # C++17 filesystem support
    "-C", "link-arg=-lgcc_s",
    "-C", "link-arg=-lm",
    "-C", "link-arg=-ldl",
    "-C", "link-arg=-lpthread",
    "-C", "link-arg=-lc",                           # C library LAST
    "-C", "link-arg=-Wl,--as-needed",
    # rpath entries with GCC 9 library path
    "-C", "link-arg=-Wl,-rpath=/usr/lib/gcc/x86_64-linux-gnu/9",
    # ... other rpath entries ...
]
```

**How This Fixes GCC 9 Issues with lld:**

The `--unresolved-symbols=ignore-in-object-files` flag is lld-specific and:
1. **Tells lld**: "Unresolved symbols in object files are OK - don't error"
2. **Defers to dynamic linker**: At runtime, `ld.so` finds C++ ABI symbols in system libstdc++.so.6
3. **Why it works**: System libstdc++.so.6 contains modern C++ ABI symbols (GLIBCXX_3.4.35+) even on GCC 9 systems
4. **Proper lld handling**: This is the correct way to handle ABI mismatches with lld

**Why This Works in All Contexts:**
- ✓ Works with GNU ld (BFD linker) - more flexible
- ✓ Works with LLVM's lld linker (dependency context)
- ✓ Works on GCC 9 systems (runtime resolution)
- ✓ Works on GCC 11+ systems (native compatibility)
- ✓ Works in standalone builds
- ✓ Works in Erlang dependency builds (`/opt/exapi/_build/...`)

### Symptom 3: glibc Version Mismatch (< 2.32)

**Symptoms:**
- Build succeeds, but binary fails at runtime with:
  ```
  symbol lookup error: undefined symbol: __libc_single_threaded
  ```
- System has glibc 2.31 or older: `ldd --version` shows "GLIBC 2.31"
- ONNX Runtime was compiled with glibc 2.32+ (which has `__libc_single_threaded`)

**Root Cause:**
- `__libc_single_threaded` is a glibc symbol added in version 2.32
- Older glibc versions (2.31 and earlier) don't have it
- ONNX Runtime expects it at runtime, causing dynamic linker failure

**Solution: Provide Weak Symbol Definition**

This is configured in `build.rs`:
```rust
// Weak definition of __libc_single_threaded for glibc < 2.32 compatibility
int __libc_single_threaded __attribute__((weak)) = 0;
```

**How This Fixes glibc Mismatch:**
1. **During compile**: `build.rs` compiles `libc_compat.c` with weak symbol definition
2. **During link**: The weak symbol gets linked into our binary
3. **At runtime**: If glibc provides the symbol (glibc 2.32+), it overrides the weak version
4. **Fallback**: If glibc doesn't have it (glibc 2.31-), our weak definition is used
5. **Result**: Binary works on glibc 2.31+ systems

**Files Modified:**
- `native_gliner_worker/build.rs` - New file with glibc compatibility logic
- `native_gliner_worker/Cargo.toml` - Added `cc` build dependency

### Verification & Testing

**For Parent Erlang Application (Dependency Context):**

Clean and rebuild:
```bash
cd /path/to/parent/erlang/app
rebar3 clean
rebar3 compile
```

The `.cargo/config.toml` configuration handles all C++ linking and GCC version compatibility automatically.

**For Standalone Builds:**

```bash
make build        # Standalone build
make test-suite   # Run all tests
```

### If Build Still Fails

#### Step 1: Verify GCC Version

```bash
gcc --version
```

If GCC 9.x:
```bash
# Check if newer GCC is available
update-alternatives --list gcc 2>/dev/null || echo "No alternatives configured"

# Or check what's installed
dpkg -l | grep "^ii.*gcc-" | awk '{print $2, $3}'
```

#### Step 2: Verify libstdc++ Has Modern ABI Symbols

```bash
# Check available GLIBCXX versions
strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 | grep "^GLIBCXX_" | sort -u | tail -3

# Should show GLIBCXX_3.4.30+ (not 3.4.9)
```

#### Step 3: Force Rebuild with Proper Linker Flags

The key flag is `-Wl,--allow-shlib-undefined`, which works with any linker:

```bash
cd /path/to/project
RUSTFLAGS="-C link-arg=-Wl,--allow-shlib-undefined" cargo build --release
```

This flag tells the linker to defer undefined C++ symbol resolution to the runtime dynamic linker (ld.so), which is the correct approach for mixed-ABI scenarios.

#### Step 4: If Build Still Fails After Flag Application

### Why This Fix Works

1. **`--allow-shlib-undefined` flag**: The critical fix
   - Tells linker: "Some symbols will be resolved at runtime"
   - Dynamic linker (ld.so) finds C++ ABI symbols in system libstdc++.so.6
   - Works with ANY linker (GNU ld, LLVM lld, gold, etc.)
   - This is the proper way to handle ABI mismatches

2. **Library linking order**: C++ before C
   - Ensures C++ runtime initialization happens first
   - Proper symbol dependency resolution

3. **`-Wl,--no-as-needed` around critical libs**: Prevents symbol stripping
   - Keeps C++ ABI initialization symbols even if marked unused
   
4. **rpath configuration**: Ensures runtime libstdc++ discovery
   - Multiple paths checked: `/usr/lib/x86_64-linux-gnu`, `/usr/lib64`, `/lib/x86_64-linux-gnu`, `/lib64`
   - Works across different Linux distributions

**This approach works on:**
- ✓ GCC 9.x with modern libstdc++ (ABI mismatch scenario)
- ✓ GCC 11+ (native modern ABI)
- ✓ Standalone builds
- ✓ **Dependency context** (nested Erlang app builds with lld)
- ✓ Both GNU ld and LLVM lld linkers
- ✓ Docker/CI environments with mixed GCC versions

## For CI/CD Pipelines and Docker

### Using the GCC 9 Compatibility Wrapper

If your CI/CD system may have GCC 9.x or unknown GCC versions, use the compatibility wrapper:

**Standalone build:**
```bash
bash build-with-gcc9-compat.sh
```

**In CI/CD pipeline:**
```yaml
script:
  - bash build-with-gcc9-compat.sh  # Auto-detects GCC and applies fixes
  - make test-suite                  # Run tests
```

The wrapper:
- ✓ Detects GCC version
- ✓ Checks libstdc++ ABI compatibility
- ✓ Applies GCC 9 workarounds if needed
- ✓ Provides diagnostic output

### Docker Build Example (GCC 9 System)

```dockerfile
FROM ubuntu:20.04

RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    binutils  # Ensures GNU ld (BFD) is available

WORKDIR /app
COPY . .

# Use the compatibility wrapper
RUN bash build-with-gcc9-compat.sh

# Optional: Run tests
RUN make test-suite
```

### Docker Build Example (Modern GCC)

```dockerfile
FROM ubuntu:24.04  # Has GCC 13+

RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev

WORKDIR /app
COPY . .

# Standard build works fine
RUN make build
```

### CI/CD Best Practices

1. **Check GCC version early:**
   ```bash
   gcc --version
   ```

2. **Install binutils if not present:**
   ```bash
   # Debian/Ubuntu
   apt-get install -y binutils
   # CentOS/RHEL
   yum install -y binutils
   ```

3. **Use compatibility wrapper if GCC 9.x detected:**
   ```bash
   if gcc -dumpversion | grep -q "^9\."; then
       bash build-with-gcc9-compat.sh
   else
       make build
   fi
   ```

4. **Log system information for debugging:**
   ```bash
   gcc --version
   ldd --version
   ldconfig -p | grep libstdc++
   ```

## References

- [ONNX Runtime System Library](https://crates.io/crates/ort-sys)
- [Rust Linker Arguments](https://doc.rust-lang.org/rustc/codegen-options/index.html)
- [Cargo Build Configuration](https://doc.rust-lang.org/cargo/reference/config.html)
- [GCC C++ ABI Compatibility](https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html)
