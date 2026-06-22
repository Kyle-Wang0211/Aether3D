#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Lazily-built shared Metal context (device, queue, both pipelines).
static id<MTLDevice> gDev;
static id<MTLCommandQueue> gQueue;
static id<MTLComputePipelineState> gNaive;  // pw_match_kernel  (fp32)
static id<MTLComputePipelineState> gTiled;  // pw_match_tiled   (fp16 + tiling)
static id<MTLComputePipelineState> gGemm;   // pw_match_gemm    (simdgroup_matrix)

static BOOL ensureMetal(void) {
  if (gDev) return YES;
  gDev = MTLCreateSystemDefaultDevice();
  if (!gDev) return NO;
  gQueue = [gDev newCommandQueue];
  id<MTLLibrary> lib = [gDev newDefaultLibrary];
  if (!lib) return NO;
  NSError* e = nil;
  id<MTLFunction> f1 = [lib newFunctionWithName:@"pw_match_kernel"];
  id<MTLFunction> f2 = [lib newFunctionWithName:@"pw_match_tiled"];
  id<MTLFunction> f3 = [lib newFunctionWithName:@"pw_match_gemm"];
  if (f1) gNaive = [gDev newComputePipelineStateWithFunction:f1 error:&e];
  if (f2) gTiled = [gDev newComputePipelineStateWithFunction:f2 error:&e];
  if (f3) gGemm = [gDev newComputePipelineStateWithFunction:f3 error:&e];
  return (gNaive != nil || gTiled != nil);
}

// Mutual cross-check over the two one-way result buffers.
static int crossCheck(const int* mAB, int nA, const int* mBA, int nB) {
  int n = 0;
  for (int i = 0; i < nA; ++i) {
    int j = mAB[i];
    if (j >= 0 && j < nB && mBA[j] == i) ++n;
  }
  return n;
}

// ── v0: naive fp32 brute-force (baseline) ────────────────────────────────
int aether_gpu_match(const uint8_t* dA, int nA, const uint8_t* dB, int nB,
                     double max_ratio, int* out_matches) {
  @autoreleasepool {
    if (out_matches) *out_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (!ensureMetal() || !gNaive) return 2;
    const int D = 128;
    id<MTLBuffer> aBuf = [gDev newBufferWithLength:(NSUInteger)nA * D * sizeof(float)
                                          options:MTLResourceStorageModeShared];
    id<MTLBuffer> bBuf = [gDev newBufferWithLength:(NSUInteger)nB * D * sizeof(float)
                                          options:MTLResourceStorageModeShared];
    if (!aBuf || !bBuf) return 5;
    float* af = (float*)aBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (float)dA[i];
    float* bf = (float*)bBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (float)dB[i];
    id<MTLBuffer> outAB = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(int)
                                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBA = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(int)
                                           options:MTLResourceStorageModeShared];
    float ratioSq = (float)(max_ratio * max_ratio);
    if (ratioSq <= 0.0f) ratioSq = 0.49f;
    void (^disp)(id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, uint32_t, uint32_t) =
        ^(id<MTLBuffer> Q, id<MTLBuffer> Db, id<MTLBuffer> O, uint32_t nQ, uint32_t nDb) {
          id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
          id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
          [enc setComputePipelineState:gNaive];
          [enc setBuffer:Q offset:0 atIndex:0];
          [enc setBuffer:Db offset:0 atIndex:1];
          [enc setBuffer:O offset:0 atIndex:2];
          [enc setBytes:&nQ length:4 atIndex:3];
          [enc setBytes:&nDb length:4 atIndex:4];
          [enc setBytes:&ratioSq length:4 atIndex:5];
          NSUInteger tg = MIN(gNaive.maxTotalThreadsPerThreadgroup, (NSUInteger)256);
          [enc dispatchThreads:MTLSizeMake(nQ, 1, 1)
              threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
          [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
        };
    disp(aBuf, bBuf, outAB, (uint32_t)nA, (uint32_t)nB);
    disp(bBuf, aBuf, outBA, (uint32_t)nB, (uint32_t)nA);
    if (out_matches)
      *out_matches = crossCheck((const int*)outAB.contents, nA,
                                (const int*)outBA.contents, nB);
    return 0;
  }
}

// ── v1: fp16 storage + threadgroup tiling, fp32 math ─────────────────────
int aether_gpu_match_tiled(const uint8_t* dA, int nA, const uint8_t* dB, int nB,
                           double max_ratio, int* out_matches) {
  @autoreleasepool {
    if (out_matches) *out_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (!ensureMetal() || !gTiled) return 2;
    const int D = 128;
    id<MTLBuffer> aBuf = [gDev newBufferWithLength:(NSUInteger)nA * D * sizeof(__fp16)
                                          options:MTLResourceStorageModeShared];
    id<MTLBuffer> bBuf = [gDev newBufferWithLength:(NSUInteger)nB * D * sizeof(__fp16)
                                          options:MTLResourceStorageModeShared];
    if (!aBuf || !bBuf) return 5;
    __fp16* af = (__fp16*)aBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (__fp16)dA[i];
    __fp16* bf = (__fp16*)bBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (__fp16)dB[i];
    id<MTLBuffer> outAB = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(int)
                                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBA = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(int)
                                           options:MTLResourceStorageModeShared];
    float ratioSq = (float)(max_ratio * max_ratio);
    if (ratioSq <= 0.0f) ratioSq = 0.49f;
    const NSUInteger TILE = 32;          // must match kTILE in the kernel
    const NSUInteger TG = 64;
    const NSUInteger tgMem = (TG + TILE) * 128 * sizeof(__fp16);  // 24 KB (qtile+btile)
    // Both one-way passes in ONE command buffer (independent outputs → GPU can
    // overlap; a single commit/wait instead of two round-trips).
    id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
    void (^enc2)(id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, uint32_t, uint32_t) =
        ^(id<MTLBuffer> Q, id<MTLBuffer> Db, id<MTLBuffer> O, uint32_t nQ, uint32_t nDb) {
          id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
          [enc setComputePipelineState:gTiled];
          [enc setBuffer:Q offset:0 atIndex:0];
          [enc setBuffer:Db offset:0 atIndex:1];
          [enc setBuffer:O offset:0 atIndex:2];
          [enc setBytes:&nQ length:4 atIndex:3];
          [enc setBytes:&nDb length:4 atIndex:4];
          [enc setBytes:&ratioSq length:4 atIndex:5];
          [enc setThreadgroupMemoryLength:tgMem atIndex:0];
          [enc dispatchThreads:MTLSizeMake(nQ, 1, 1)
              threadsPerThreadgroup:MTLSizeMake(TG, 1, 1)];
          [enc endEncoding];
        };
    enc2(aBuf, bBuf, outAB, (uint32_t)nA, (uint32_t)nB);
    enc2(bBuf, aBuf, outBA, (uint32_t)nB, (uint32_t)nA);
    [cmd commit];
    [cmd waitUntilCompleted];
    if (out_matches)
      *out_matches = crossCheck((const int*)outAB.contents, nA,
                                (const int*)outBA.contents, nB);
    return 0;
  }
}

// GEMM matcher via simdgroup_matrix (tensor-core) — pw_match_gemm. Same C ABI;
// uploads uint8->half, binds 8 buffers + 3 threadgroup scratch (Ash 2KB / Bsh
// 16KB / acc 2KB), one simdgroup (32 lanes) per 8-row A-block, both passes in
// one command buffer + mutual cross-check.
int aether_gpu_match_gemm(const uint8_t* dA, int nA, const uint8_t* dB, int nB,
                          double max_ratio, int* out_matches) {
  @autoreleasepool {
    if (out_matches) *out_matches = 0;
    if (!dA || !dB || nA <= 0 || nB <= 0) return 1;
    if (!ensureMetal() || !gGemm) return 2;
    const int D = 128;
    // pad query buffers to a multiple of kMB(64) rows so the kernel's device-side
    // simdgroup_load of A never reads OOB; padding rows are zero (guarded out).
    NSUInteger nApad = (((NSUInteger)nA + 127) / 128) * 128;
    NSUInteger nBpad = (((NSUInteger)nB + 127) / 128) * 128;
    id<MTLBuffer> aBuf = [gDev newBufferWithLength:nApad * D * sizeof(__fp16)
                                          options:MTLResourceStorageModeShared];
    id<MTLBuffer> bBuf = [gDev newBufferWithLength:nBpad * D * sizeof(__fp16)
                                          options:MTLResourceStorageModeShared];
    if (!aBuf || !bBuf) return 5;
    __fp16* af = (__fp16*)aBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nA * D; ++i) af[i] = (__fp16)dA[i];
    for (NSUInteger i = (NSUInteger)nA * D; i < nApad * D; ++i) af[i] = 0;
    __fp16* bf = (__fp16*)bBuf.contents;
    for (NSUInteger i = 0; i < (NSUInteger)nB * D; ++i) bf[i] = (__fp16)dB[i];
    for (NSUInteger i = (NSUInteger)nB * D; i < nBpad * D; ++i) bf[i] = 0;
    id<MTLBuffer> outAB = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBA = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(int)
                                            options:MTLResourceStorageModeShared];
    if (!outAB || !outBA) return 6;
    float ratioSq = (float)(max_ratio * max_ratio);
    if (ratioSq <= 0.0f) ratioSq = 0.49f;
    const NSUInteger bshLen = 16 * 128 * sizeof(__fp16);  // 4 KB  (kBN*kD)
    const NSUInteger accLen = 128 * 16 * sizeof(float);   // 8 KB  (kMB*kBN)
    // host-precomputed squared norms (||a||^2, ||b||^2) — kernel uses these
    // (COMPUTE_NORMS_INLINE=0) instead of recomputing per-strip in the hot loop.
    id<MTLBuffer> normA = [gDev newBufferWithLength:(NSUInteger)nA * sizeof(float)
                                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> normB = [gDev newBufferWithLength:(NSUInteger)nB * sizeof(float)
                                            options:MTLResourceStorageModeShared];
    float* na = (float*)normA.contents;
    for (int i = 0; i < nA; ++i) { float s = 0; const uint8_t* a = dA + (size_t)i * D;
      for (int d = 0; d < D; ++d) { float v = (float)a[d]; s += v * v; } na[i] = s; }
    float* nb = (float*)normB.contents;
    for (int i = 0; i < nB; ++i) { float s = 0; const uint8_t* b = dB + (size_t)i * D;
      for (int d = 0; d < D; ++d) { float v = (float)b[d]; s += v * v; } nb[i] = s; }
    id<MTLCommandBuffer> cmd = [gQueue commandBuffer];
    // NQ = squared norms of the QUERY set, NDb = of the DB set (swap per pass).
    void (^enc2)(id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, id<MTLBuffer>, uint32_t, uint32_t) =
        ^(id<MTLBuffer> Q, id<MTLBuffer> Db, id<MTLBuffer> O, id<MTLBuffer> NQ, id<MTLBuffer> NDb, uint32_t nQ, uint32_t nDb) {
          id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
          [enc setComputePipelineState:gGemm];
          [enc setBuffer:Q offset:0 atIndex:0];
          [enc setBuffer:Db offset:0 atIndex:1];
          [enc setBuffer:O offset:0 atIndex:2];
          [enc setBytes:&nQ length:4 atIndex:3];
          [enc setBytes:&nDb length:4 atIndex:4];
          [enc setBytes:&ratioSq length:4 atIndex:5];
          [enc setBuffer:NQ offset:0 atIndex:6];
          [enc setBuffer:NDb offset:0 atIndex:7];
          [enc setThreadgroupMemoryLength:bshLen atIndex:0];
          [enc setThreadgroupMemoryLength:accLen atIndex:1];
          NSUInteger groups = (nQ + 127) / 128;   // kMB=128 A-rows per group
          [enc dispatchThreadgroups:MTLSizeMake(groups, 1, 1)
              threadsPerThreadgroup:MTLSizeMake(512, 1, 1)];  // kSG*32 = 16 simdgroups
          [enc endEncoding];
        };
    enc2(aBuf, bBuf, outAB, normA, normB, (uint32_t)nA, (uint32_t)nB);   // A->B
    enc2(bBuf, aBuf, outBA, normB, normA, (uint32_t)nB, (uint32_t)nA);   // B->A
    [cmd commit];
    [cmd waitUntilCompleted];
    if (out_matches)
      *out_matches = crossCheck((const int*)outAB.contents, nA,
                                (const int*)outBA.contents, nB);
    return 0;
  }
}
