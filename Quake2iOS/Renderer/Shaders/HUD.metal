/*
 * HUD.metal
 * Metal shaders for 2D HUD/menu rendering
 * Used for DrawPic, DrawChar, DrawFill, DrawStretchPic, etc.
 */

#include <metal_stdlib>
using namespace metal;
#include "../RendererTypes.h"

struct HUDVertexOut {
    float4 position [[position]];
    float2 texcoord;
    float4 color;
};

vertex HUDVertexOut hud_vertex(
    const device Q2HUDVertex *vertices [[buffer(0)]],
    constant float4x4 &orthoMatrix [[buffer(1)]],
    uint vid [[vertex_id]])
{
    HUDVertexOut out;
    out.position = orthoMatrix * float4(vertices[vid].position, 0.0, 1.0);
    out.texcoord = vertices[vid].texcoord;
    out.color = vertices[vid].color;
    return out;
}

/* Textured HUD elements (pics, characters) */
fragment float4 hud_textured_fragment(
    HUDVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler texSampler [[sampler(0)]])
{
    float4 texColor = tex.sample(texSampler, in.texcoord);

    /* Alpha test for conchars (character atlas) */
    if (texColor.a < 0.1)
        discard_fragment();

    return texColor * in.color;
}

/* Solid color fill (DrawFill, DrawFadeScreen) */
fragment float4 hud_solid_fragment(
    HUDVertexOut in [[stage_in]])
{
    return in.color;
}

/* Cinematic raw drawing (DrawStretchRaw) */
fragment float4 hud_raw_fragment(
    HUDVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler texSampler [[sampler(0)]])
{
    return tex.sample(texSampler, in.texcoord);
}
