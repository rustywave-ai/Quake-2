/*
 * Particle.metal
 * Metal shaders for particle rendering
 */

#include <metal_stdlib>
using namespace metal;
#include "../RendererTypes.h"

struct ParticleVertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

vertex ParticleVertexOut particle_vertex(
    const device Q2ParticleVertex *particles [[buffer(0)]],
    constant Q2FrameUniforms &uniforms [[buffer(1)]],
    uint vid [[vertex_id]])
{
    ParticleVertexOut out;

    float4 worldPos = float4(particles[vid].position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.color = particles[vid].color;

    /* Scale point size by distance */
    float dist = length(particles[vid].position - uniforms.viewOrigin);
    out.pointSize = max(1.0, particles[vid].size * 300.0 / max(dist, 1.0));

    return out;
}

fragment float4 particle_fragment(
    ParticleVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]])
{
    /* Circular particle with soft edge */
    float dist = length(pointCoord - float2(0.5));
    if (dist > 0.5)
        discard_fragment();

    float alpha = in.color.a * smoothstep(0.5, 0.3, dist);
    return float4(in.color.rgb, alpha);
}
