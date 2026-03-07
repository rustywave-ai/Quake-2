/*
 * Alias.metal
 * Metal shaders for MD2 alias model rendering
 * Supports vertex lerp between frames in the vertex shader
 */

#include <metal_stdlib>
using namespace metal;
#include "../RendererTypes.h"

struct AliasVertexOut {
    float4 position [[position]];
    float2 texcoord;
    float3 normal;
    float alpha;
};

vertex AliasVertexOut alias_vertex(
    const device Q2AliasVertex *vertices [[buffer(Q2BufferIndexVertices)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    constant Q2ModelUniforms &modelUniforms [[buffer(Q2BufferIndexModelUniforms)]],
    uint vid [[vertex_id]])
{
    AliasVertexOut out;

    /* Lerp between current and old frame positions */
    float3 pos = mix(vertices[vid].position,
                     vertices[vid].oldPosition,
                     modelUniforms.backlerp);

    float4 worldPos = modelUniforms.modelMatrix * float4(pos, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.texcoord = vertices[vid].texcoord;
    out.normal = (modelUniforms.modelMatrix * float4(vertices[vid].normal, 0.0)).xyz;
    out.alpha = modelUniforms.alpha;

    return out;
}

fragment float4 alias_fragment(
    AliasVertexOut in [[stage_in]],
    texture2d<float> skinTex [[texture(Q2TextureIndexDiffuse)]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]],
    sampler texSampler [[sampler(0)]])
{
    float4 color = skinTex.sample(texSampler, in.texcoord);

    if (color.a < 0.1)
        discard_fragment();

    /* Simple directional lighting from above */
    float3 lightDir = normalize(float3(0.0, 0.0, 1.0));
    float ndotl = max(dot(normalize(in.normal), lightDir), 0.3);

    float3 result = color.rgb * ndotl;
    result = pow(result, float3(uniforms.gamma));

    return float4(result, in.alpha);
}

/* Shell effect variant (power-ups like quad damage) */
fragment float4 alias_shell_fragment(
    AliasVertexOut in [[stage_in]],
    constant Q2FrameUniforms &uniforms [[buffer(Q2BufferIndexFrameUniforms)]])
{
    /* Pulsing shell color */
    float pulse = sin(uniforms.time * 3.0) * 0.3 + 0.7;
    return float4(0.0, pulse, 0.0, 0.3); /* Default green shell */
}
