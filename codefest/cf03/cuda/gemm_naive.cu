// gemm_naive.cu
// CF03 CLLM - Naive CUDA GEMM (1024x1024 FP32)
// One thread per output element C[i][j] = sum_k A[i][k] * B[k][j]
//
// Compile: nvcc -O2 -o gemm_naive gemm_naive.cu
// Run    : ./gemm_naive

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define N 1024
#define BLOCK 16   // 16x16 = 256 threads/block

#define CUDA_CHECK(call) do {                                         \
    cudaError_t err = (call);                                         \
    if (err != cudaSuccess) {                                         \
        fprintf(stderr, "CUDA error %s:%d: %s\n",                     \
                __FILE__, __LINE__, cudaGetErrorString(err));         \
        exit(EXIT_FAILURE);                                           \
    }                                                                 \
} while (0)

// Naive kernel: each thread computes one C[row][col].
// Every multiply-add issues two global-memory loads (A and B) -> no reuse.
__global__ void gemm_naive(const float* __restrict__ A,
                           const float* __restrict__ B,
                           float* __restrict__ C,
                           int n) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < n && col < n) {
        float acc = 0.0f;
        for (int k = 0; k < n; ++k) {
            acc += A[row * n + k] * B[k * n + col];
        }
        C[row * n + col] = acc;
    }
}

int main() {
    size_t bytes = (size_t)N * N * sizeof(float);

    // Host allocations
    float *hA = (float*)malloc(bytes);
    float *hB = (float*)malloc(bytes);
    float *hC = (float*)malloc(bytes);
    for (int i = 0; i < N * N; ++i) {
        hA[i] = (float)((i % 13) - 6) * 0.01f;
        hB[i] = (float)((i % 17) - 8) * 0.01f;
    }

    // Device allocations
    float *dA, *dB, *dC;
    CUDA_CHECK(cudaMalloc(&dA, bytes));
    CUDA_CHECK(cudaMalloc(&dB, bytes));
    CUDA_CHECK(cudaMalloc(&dC, bytes));

    CUDA_CHECK(cudaMemcpy(dA, hA, bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dB, hB, bytes, cudaMemcpyHostToDevice));

    dim3 block(BLOCK, BLOCK);
    dim3 grid((N + BLOCK - 1) / BLOCK, (N + BLOCK - 1) / BLOCK);

    // Warm-up (excluded from timing)
    gemm_naive<<<grid, block>>>(dA, dB, dC, N);
    CUDA_CHECK(cudaDeviceSynchronize());

    // Timed runs
    const int ITERS = 20;
    cudaEvent_t start, stop;
    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));

    CUDA_CHECK(cudaEventRecord(start));
    for (int it = 0; it < ITERS; ++it) {
        gemm_naive<<<grid, block>>>(dA, dB, dC, N);
    }
    CUDA_CHECK(cudaEventRecord(stop));
    CUDA_CHECK(cudaEventSynchronize(stop));

    float ms_total = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms_total, start, stop));
    float ms_per_iter = ms_total / ITERS;

    // FLOPs per GEMM: 2 * N^3 (one multiply + one add per inner iteration)
    double flops = 2.0 * (double)N * (double)N * (double)N;
    double gflops = (flops / (ms_per_iter * 1.0e-3)) / 1.0e9;

    CUDA_CHECK(cudaMemcpy(hC, dC, bytes, cudaMemcpyDeviceToHost));

    // Sanity check: print one element
    printf("=== gemm_naive (N=%d, FP32) ===\n", N);
    printf("block=%dx%d  grid=%dx%d  iters=%d\n",
           BLOCK, BLOCK, grid.x, grid.y, ITERS);
    printf("avg kernel time : %.4f ms\n", ms_per_iter);
    printf("achieved        : %.2f GFLOP/s\n", gflops);
    printf("C[0]=%.6f  C[N*N-1]=%.6f\n", hC[0], hC[N*N - 1]);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    free(hA); free(hB); free(hC);
    return 0;
}
