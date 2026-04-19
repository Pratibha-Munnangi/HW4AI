// gemm_tiled.cu
// CF03 CLLM - Shared-memory tiled CUDA GEMM (1024x1024 FP32)
// Tile size T = 8 (per assignment spec).
// Each thread block cooperatively loads an 8x8 tile of A and B into
// shared memory, then each thread computes one output element of an
// 8x8 tile of C using the cached values.
//
// Compile: nvcc -O2 -o gemm_tiled gemm_tiled.cu
// Run    : ./gemm_tiled

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define N 1024
#define T 8     // tile size per assignment

#define CUDA_CHECK(call) do {                                         \
    cudaError_t err = (call);                                         \
    if (err != cudaSuccess) {                                         \
        fprintf(stderr, "CUDA error %s:%d: %s\n",                     \
                __FILE__, __LINE__, cudaGetErrorString(err));         \
        exit(EXIT_FAILURE);                                           \
    }                                                                 \
} while (0)

// Tiled kernel: blockDim = (T, T) = (8, 8) -> 64 threads per block.
// Each block computes one TxT tile of C by streaming N/T tiles of
// A (along columns) and B (along rows) through shared memory.
__global__ void gemm_tiled(const float* __restrict__ A,
                           const float* __restrict__ B,
                           float* __restrict__ C,
                           int n) {
    __shared__ float As[T][T];
    __shared__ float Bs[T][T];

    int tx = threadIdx.x;
    int ty = threadIdx.y;
    int row = blockIdx.y * T + ty;
    int col = blockIdx.x * T + tx;

    float acc = 0.0f;

    // Number of tiles along the K dimension
    int numTiles = n / T;
    for (int m = 0; m < numTiles; ++m) {
        // Cooperative load: each thread loads one element of As and Bs
        As[ty][tx] = A[row * n + (m * T + tx)];
        Bs[ty][tx] = B[(m * T + ty) * n + col];
        __syncthreads();

        // Multiply the two tiles
        #pragma unroll
        for (int k = 0; k < T; ++k) {
            acc += As[ty][k] * Bs[k][tx];
        }
        __syncthreads();
    }

    C[row * n + col] = acc;
}

int main() {
    size_t bytes = (size_t)N * N * sizeof(float);

    float *hA = (float*)malloc(bytes);
    float *hB = (float*)malloc(bytes);
    float *hC = (float*)malloc(bytes);
    for (int i = 0; i < N * N; ++i) {
        hA[i] = (float)((i % 13) - 6) * 0.01f;
        hB[i] = (float)((i % 17) - 8) * 0.01f;
    }

    float *dA, *dB, *dC;
    CUDA_CHECK(cudaMalloc(&dA, bytes));
    CUDA_CHECK(cudaMalloc(&dB, bytes));
    CUDA_CHECK(cudaMalloc(&dC, bytes));

    CUDA_CHECK(cudaMemcpy(dA, hA, bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dB, hB, bytes, cudaMemcpyHostToDevice));

    dim3 block(T, T);
    dim3 grid(N / T, N / T);

    // Warm-up
    gemm_tiled<<<grid, block>>>(dA, dB, dC, N);
    CUDA_CHECK(cudaDeviceSynchronize());

    const int ITERS = 20;
    cudaEvent_t start, stop;
    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));

    CUDA_CHECK(cudaEventRecord(start));
    for (int it = 0; it < ITERS; ++it) {
        gemm_tiled<<<grid, block>>>(dA, dB, dC, N);
    }
    CUDA_CHECK(cudaEventRecord(stop));
    CUDA_CHECK(cudaEventSynchronize(stop));

    float ms_total = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&ms_total, start, stop));
    float ms_per_iter = ms_total / ITERS;

    double flops = 2.0 * (double)N * (double)N * (double)N;
    double gflops = (flops / (ms_per_iter * 1.0e-3)) / 1.0e9;

    CUDA_CHECK(cudaMemcpy(hC, dC, bytes, cudaMemcpyDeviceToHost));

    printf("=== gemm_tiled (N=%d, T=%d, FP32) ===\n", N, T);
    printf("block=%dx%d  grid=%dx%d  iters=%d\n",
           T, T, grid.x, grid.y, ITERS);
    printf("avg kernel time : %.4f ms\n", ms_per_iter);
    printf("achieved        : %.2f GFLOP/s\n", gflops);
    printf("C[0]=%.6f  C[N*N-1]=%.6f\n", hC[0], hC[N*N - 1]);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(dA); cudaFree(dB); cudaFree(dC);
    free(hA); free(hB); free(hC);
    return 0;
}
