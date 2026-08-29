#!/bin/sh
# Compile-check the CUDA sources embedded in nvidia-gpu.sh without a GPU or
# the CUDA toolkit: stub the runtime, strip the <<<grid,block>>> launch syntax
# and let a host C++ compiler parse it.
#   sh tests/cuda_syntax_check.sh [path/to/nvidia-gpu.sh]
SRC=${1:-scripts/nvidia-gpu.sh}
[ -r "$SRC" ] || { echo "cannot read $SRC"; exit 2; }
command -v g++ >/dev/null 2>&1 || { echo "  SKIP  no g++ available"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0

cat > "$W/cuda_runtime.h" <<'STUB'
// minimal stand-in for the CUDA runtime, enough to type-check kernel code
#pragma once
#include <cstddef>
#include <cstring>
#define __global__
#define __device__
#define __host__
#define __forceinline__ inline
struct os_dim3 { unsigned x, y, z; };
static os_dim3 blockIdx, blockDim, threadIdx, gridDim;
typedef int cudaError_t;
enum { cudaSuccess = 0 };
enum cudaMemcpyKind { cudaMemcpyHostToDevice, cudaMemcpyDeviceToHost };
static inline cudaError_t cudaMalloc(void **p, size_t n) { *p = ::operator new(n); return cudaSuccess; }
static inline cudaError_t cudaFree(void *p) { ::operator delete(p); return cudaSuccess; }
static inline cudaError_t cudaMemset(void *p, int v, size_t n) { memset(p, v, n); return cudaSuccess; }
static inline cudaError_t cudaMemcpy(void *d, const void *s, size_t n, cudaMemcpyKind) { memcpy(d, s, n); return cudaSuccess; }
static inline cudaError_t cudaMemGetInfo(size_t *f, size_t *t) { *f = 1u << 30; *t = 2u << 30; return cudaSuccess; }
static inline cudaError_t cudaDeviceSynchronize(void) { return cudaSuccess; }
template <typename T> static inline T atomicAdd(T *p, T v) { T o = *p; *p += v; return o; }
static inline float fmaf(float a, float b, float c) { return a * b + c; }
STUB

extract() { # marker -> source on stdout
    awk -v m="$1" '
        $0 ~ ("<<[\047]" m "[\047]") { inb = 1; next }
        inb && $0 ~ ("^" m "$")      { inb = 0 }
        inb                          { print }' "$SRC"
}

for pair in "CUEOF:burn" "VREOF:vramtest"; do
    marker=${pair%%:*}
    name=${pair#*:}
    extract "$marker" > "$W/$name.cpp.raw"
    if [ ! -s "$W/$name.cpp.raw" ]; then
        printf '  FAIL  could not extract the %s source (marker %s)\n' "$name" "$marker"
        FAILED=$((FAILED + 1))
        continue
    fi
    # turn "kernel<<<a, b>>>(args);" into a plain call so C++ can parse it
    sed -e 's/<<<[^>]*>>>//g' "$W/$name.cpp.raw" > "$W/$name.cpp"
    if g++ -std=c++14 -fsyntax-only -Wall -Wextra -Wno-unused-parameter \
           -I"$W" -include cuda_runtime.h "$W/$name.cpp" 2> "$W/$name.log"; then
        printf '  ok    %s.cu compiles (%s lines)\n' "$name" "$(wc -l < "$W/$name.cpp" | tr -d ' ')"
        if [ -s "$W/$name.log" ]; then
            printf '        warnings:\n'
            sed 's/^/        /' "$W/$name.log"
        fi
    else
        printf '  FAIL  %s.cu does not compile:\n' "$name"
        sed 's/^/        /' "$W/$name.log"
        FAILED=$((FAILED + 1))
    fi
done

printf '\n'
[ "$FAILED" = "0" ] && { echo "embedded CUDA sources compile"; exit 0; }
echo "$FAILED CUDA source(s) FAILED"
exit 1
