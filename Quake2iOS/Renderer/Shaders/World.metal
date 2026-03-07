/*
 * World.metal
 * Metal shaders for BSP world surface rendering
 */

#include <metal_stdlib>
using namespace metal;
#include "../RendererTypes.h"

struct WorldVertexOut {
    float4 position [[position]];
    float2 texcoord;
    float2 lightmapUV;
};

vertex WorldVertexOut world_vertex(
    const device Q2WorldVertex *vertices [[buffer(Q2BufferIndexVertices)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    uint vid [[vertex_id]])
{
    WorldVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(vertices[vid].position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.texcoord = vertices[vid].texcoord;
    out.lightmapUV = vertices[vid].lightmapUV;
    return out;
}

fragment float4 world_fragment(
    WorldVertexOut in [[stage_in]],
    texture2d<float> diffuseTex [[texture(Q2TextureIndexDiffuse)]],
    texture2d<float> lightmapTex [[texture(Q2TextureIndexLightmap)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    sampler texSampler [[sampler(0)]])
{
    float4 color = diffuseTex.sample(texSampler, in.texcoord);
    float3 light = lightmapTex.sample(texSampler, in.lightmapUV).rgb;

    /* Alpha test - discard fully transparent pixels */
    if (color.a < 0.1)
        discard_fragment();

    /* Apply lightmap and gamma */
    float3 result = color.rgb * light * 2.0;
    result = pow(result, float3(uniforms.gamma));

    return float4(result, color.a);
}

/* Variant for warp surfaces (water, lava) */
fragment float4 world_warp_fragment(
    WorldVertexOut in [[stage_in]],
    texture2d<float> diffuseTex [[texture(Q2TextureIndexDiffuse)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    sampler texSampler [[sampler(0)]])
{
    /* Simple sine-based warp distortion */
    float2 uv = in.texcoord;
    uv.x += sin(uv.y * 4.0 + uniforms.time) * 0.04;
    uv.y += sin(uv.x * 4.0 + uniforms.time) * 0.04;

    float4 color = diffuseTex.sample(texSampler, uv);
    float3 result = pow(color.rgb, float3(uniforms.gamma));

    return float4(result, 0.5); /* Water is translucent */
}

/* ================================================================ */
/* Beam shaders (untextured, colored 3D geometry for hyperblaster etc.) */
/* ================================================================ */

struct BeamVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex BeamVertexOut beam_vertex(
    const device Q2BeamVertex *vertices [[buffer(Q2BufferIndexVertices)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    uint vid [[vertex_id]])
{
    BeamVertexOut out;
    float4 worldPos = float4(vertices[vid].position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = vertices[vid].color;
    return out;
}

fragment float4 beam_fragment(BeamVertexOut in [[stage_in]])
{
    return in.color;
}

/* Sky surface shader */
fragment float4 world_sky_fragment(
    WorldVertexOut in [[stage_in]],
    texture2d<float> diffuseTex [[texture(Q2TextureIndexDiffuse)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    sampler texSampler [[sampler(0)]])
{
    float4 color = diffuseTex.sample(texSampler, in.texcoord);
    return float4(pow(color.rgb, float3(uniforms.gamma)), 1.0);
}
