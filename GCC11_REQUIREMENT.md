# GCC 11 Requirement

This project requires **GCC 11 or later** for compilation.

## Why GCC 11?

ONNX Runtime (used for GLiNER NER) is precompiled with modern C++ ABI (GLIBCXX 3.4.35+) that only GCC 11+ provides. Earlier versions (GCC 9, GCC 10) have incompatible C++ standard library symbols.

## Installation

On Ubuntu/Debian:
```bash
sudo apt install gcc-11 g++-11
```

## Build Configuration

The `rebar.config` automatically uses GCC 11/G++ 11:
```erlang
{pre_hooks,
 [{"(linux|darwin|win32)", compile, 
   "bash -c 'cd native_gliner_worker && CC=gcc-11 CXX=g++-11 cargo build --release'"}]}.
```

If your system default compiler is GCC 9, this explicit configuration ensures the correct compiler is used.

## Verification

To verify GCC 11 is installed:
```bash
gcc-11 --version
g++-11 --version
```

If building fails with "command not found: gcc-11", install it as shown above.
