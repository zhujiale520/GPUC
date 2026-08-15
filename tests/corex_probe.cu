#include <cuda_runtime.h>
#include <stdio.h>

__global__ static void fill_sequence(int *data, int count) {
    int index = (int)(blockIdx.x * blockDim.x + threadIdx.x);
    if (index < count) data[index] = index * 3 + 7;
}

int main(void) {
    const int count = 256;
    int host[count];
    int *device = NULL;
    cudaError_t error = cudaMalloc((void **)&device, sizeof(host));
    if (error != cudaSuccess) {
        fprintf(stderr, "cudaMalloc: %s\n", cudaGetErrorString(error));
        return 1;
    }

    fill_sequence<<<2, 128>>>(device, count);
    error = cudaDeviceSynchronize();
    if (error == cudaSuccess)
        error = cudaMemcpy(host, device, sizeof(host), cudaMemcpyDeviceToHost);
    cudaFree(device);
    if (error != cudaSuccess) {
        fprintf(stderr, "CoreX kernel: %s\n", cudaGetErrorString(error));
        return 1;
    }

    for (int index = 0; index < count; index++) {
        if (host[index] != index * 3 + 7) {
            fprintf(stderr, "mismatch at %d: got %d\n", index, host[index]);
            return 1;
        }
    }
    puts("PASS: CoreX CUDA kernel executed and returned correct data");
    return 0;
}
