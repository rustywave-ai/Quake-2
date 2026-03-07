/*
 * RendererTypes.h
 * Shared types between Metal shaders and Objective-C renderer code
 */

#ifndef RendererTypes_h
#define RendererTypes_h

#ifdef __METAL_VERSION__
/* Metal shader includes — packed_float2/3/4 and float4x4 are built-in */
#include <metal_stdlib>
using namespace metal;
#else
/* C/Objective-C includes */
#include <simd/simd.h>
typedef simd_packed_float2 packed_float2;
/* simd_packed_float3 doesn't exist; use a struct of 3 floats for tight packing */
typedef struct { float x, y, z; } packed_float3;
typedef simd_packed_float4 packed_float4;
typedef simd_float4x4 float4x4;
#endif

/* Vertex layout for BSP world surfaces */
typedef struct {
    packed_float3 position;
    packed_float2 texcoord;
    packed_float2 lightmapUV;
} Q2WorldVertex;

/* Vertex layout for MD2 alias models */
typedef struct {
    packed_float3 position;
    packed_float3 oldPosition;  /* Previous frame for lerp */
    packed_float2 texcoord;
    packed_float3 normal;
} Q2AliasVertex;

/* Vertex layout for 2D HUD/menu drawing */
typedef struct {
    packed_float2 position;
    packed_float2 texcoord;
    packed_float4 color;
} Q2HUDVertex;

/* Vertex layout for particles */
typedef struct {
    packed_float3 position;
    packed_float4 color;
    float size;
} Q2ParticleVertex;

/* Per-frame uniforms (world rendering) */
typedef struct {
    float4x4 projectionMatrix;
    float4x4 viewMatrix;
    float4x4 modelMatrix;
    packed_float3 viewOrigin;
    float time;
    float gamma;
    float _padding[3];
} Q2FrameUniforms;

/* Per-model uniforms (alias models) */
typedef struct {
    float4x4 modelMatrix;
    float backlerp;     /* 0.0 = current frame, 1.0 = old frame */
    float alpha;
    float _padding[2];
} Q2ModelUniforms;

/* Buffer indices for Metal argument table */
typedef enum {
    Q2BufferIndexVertices = 0,
    Q2BufferIndexFrameUniforms = 1,
    Q2BufferIndexModelUniforms = 2,
} Q2BufferIndex;

/* Texture indices for Metal argument table */
typedef enum {
    Q2TextureIndexDiffuse = 0,
    Q2TextureIndexLightmap = 1,
} Q2TextureIndex;

#endif /* RendererTypes_h */
