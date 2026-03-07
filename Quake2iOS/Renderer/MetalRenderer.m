/*
 * MetalRenderer.m
 * Metal renderer for Quake 2 - implements the refexport_t interface
 * Replaces ref_gl
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

#include "../../qcommon/qcommon.h"
#include "../../client/ref.h"
#include "../../qcommon/qfiles.h"
#include "ModelTypes.h"
#include "RendererTypes.h"

/* ================================================================ */
#pragma mark - Globals for BSPRenderer / ModelLoader
/* ================================================================ */

id<MTLDevice> mtl_device_global = nil;
id<MTLRenderCommandEncoder> mtl_encoder_global = nil;
id<MTLRenderPipelineState> mtl_worldPipeline = nil;
id<MTLRenderPipelineState> mtl_warpPipeline = nil;
id<MTLSamplerState> mtl_samplerState = nil;
id<MTLTexture> mtl_whiteTexture = nil;
refdef_t r_newrefdef;

/* ================================================================ */
#pragma mark - Renderer State (private)
/* ================================================================ */

static struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *metalLayer;
    id<MTLLibrary> shaderLibrary;

    /* Pipeline states */
    id<MTLRenderPipelineState> worldPipeline;
    id<MTLRenderPipelineState> warpPipeline;
    id<MTLRenderPipelineState> aliasPipeline;
    id<MTLRenderPipelineState> hudTexturedPipeline;
    id<MTLRenderPipelineState> hudSolidPipeline;
    id<MTLRenderPipelineState> particlePipeline;

    /* Depth stencil */
    id<MTLDepthStencilState> depthEnabled;
    id<MTLDepthStencilState> depthDisabled;

    /* Sampler */
    id<MTLSamplerState> nearestSampler;
    id<MTLSamplerState> linearSampler;

    /* Per-frame state */
    id<MTLCommandBuffer> currentCommandBuffer;
    id<MTLRenderCommandEncoder> currentEncoder;
    id<CAMetalDrawable> currentDrawable;
    id<MTLTexture> depthTexture;

    /* Screen dimensions (pixels — actual drawable resolution) */
    int width;
    int height;

    /* Virtual dimensions (points — what Q2 game code sees via viddef) */
    int virtualWidth;
    int virtualHeight;
    float screenScale; /* pixels per point */

    /* Renderer import functions */
    refimport_t ri;

    /* Frame uniforms */
    Q2FrameUniforms frameUniforms;

    /* HUD batch buffer */
    Q2HUDVertex hudVertices[65536];
    int hudVertexCount;
    id<MTLTexture> currentHUDTexture;

    /* Special textures */
    id<MTLTexture> whiteTexture;
    image_t *concharsImage;

    qboolean initialized;
} mtl;

/* Forward declarations */
static void Metal_FlushHUDBatch(void);

/* ================================================================ */
#pragma mark - Matrix Helpers
/* ================================================================ */

static simd_float4x4 Metal_PerspectiveMatrix(float fovyDeg, float aspect,
                                              float nearZ, float farZ)
{
    float fovyRad = fovyDeg * (M_PI / 180.0f);
    float ys = 1.0f / tanf(fovyRad * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);

    return (simd_float4x4){{
        {xs, 0,  0,          0},
        {0,  ys, 0,          0},
        {0,  0,  zs,        -1},
        {0,  0,  nearZ * zs, 0},
    }};
}

static simd_float4x4 Metal_ViewMatrix(vec3_t origin, vec3_t angles)
{
    vec3_t forward, right, up;
    AngleVectors(angles, forward, right, up);

    return (simd_float4x4){{
        {right[0],   up[0],   -forward[0],  0},
        {right[1],   up[1],   -forward[1],  0},
        {right[2],   up[2],   -forward[2],  0},
        {-DotProduct(right, origin),
         -DotProduct(up, origin),
          DotProduct(forward, origin), 1},
    }};
}

/* ================================================================ */
#pragma mark - refexport_t Implementation
/* ================================================================ */

static qboolean R_Init(void *hinstance, void *wndproc)
{
    @autoreleasepool {
        mtl.device = MTLCreateSystemDefaultDevice();
        if (!mtl.device) {
            Com_Printf("Metal_Init: no Metal device available\n");
            return false;
        }

        mtl.commandQueue = [mtl.device newCommandQueue];

        /* The real CAMetalLayer comes from IOS_SetMetalLayer() called
           by Swift before Quake2_Init().  Only configure it here;
           do NOT create a new orphan layer. */
        if (mtl.metalLayer) {
            mtl.metalLayer.device = mtl.device;
            mtl.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            mtl.metalLayer.framebufferOnly = YES;
        } else {
            Com_Printf("Metal_Init: WARNING — metalLayer not set! "
                        "Call IOS_SetMetalLayer() before R_Init().\n");
        }

        /* Load shader library */
        mtl.shaderLibrary = [mtl.device newDefaultLibrary];
        if (!mtl.shaderLibrary) {
            Com_Printf("Metal_Init: failed to load shader library\n");
            return false;
        }

        NSError *error = nil;

        /* Samplers */
        MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
        samplerDesc.minFilter = MTLSamplerMinMagFilterNearest;
        samplerDesc.magFilter = MTLSamplerMinMagFilterNearest;
        samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
        samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
        mtl.nearestSampler = [mtl.device newSamplerStateWithDescriptor:samplerDesc];

        samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        mtl.linearSampler = [mtl.device newSamplerStateWithDescriptor:samplerDesc];

        /* Depth stencil states */
        MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
        depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
        depthDesc.depthWriteEnabled = YES;
        mtl.depthEnabled = [mtl.device newDepthStencilStateWithDescriptor:depthDesc];

        depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
        depthDesc.depthWriteEnabled = NO;
        mtl.depthDisabled = [mtl.device newDepthStencilStateWithDescriptor:depthDesc];

        /* Pipeline setup */
        MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
        pipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        /* Validate shader functions */
        id<MTLFunction> fn_hud_vert = [mtl.shaderLibrary newFunctionWithName:@"hud_vertex"];
        id<MTLFunction> fn_hud_tex  = [mtl.shaderLibrary newFunctionWithName:@"hud_textured_fragment"];
        id<MTLFunction> fn_hud_sol  = [mtl.shaderLibrary newFunctionWithName:@"hud_solid_fragment"];
        id<MTLFunction> fn_w_vert   = [mtl.shaderLibrary newFunctionWithName:@"world_vertex"];
        id<MTLFunction> fn_w_frag   = [mtl.shaderLibrary newFunctionWithName:@"world_fragment"];
        id<MTLFunction> fn_w_warp   = [mtl.shaderLibrary newFunctionWithName:@"world_warp_fragment"];
        id<MTLFunction> fn_a_vert   = [mtl.shaderLibrary newFunctionWithName:@"alias_vertex"];
        id<MTLFunction> fn_a_frag   = [mtl.shaderLibrary newFunctionWithName:@"alias_fragment"];
        id<MTLFunction> fn_p_vert   = [mtl.shaderLibrary newFunctionWithName:@"particle_vertex"];
        id<MTLFunction> fn_p_frag   = [mtl.shaderLibrary newFunctionWithName:@"particle_fragment"];

        Com_Printf("Metal shaders loaded OK\n");

        /* HUD textured pipeline (alpha blending) */
        pipeDesc.vertexFunction = fn_hud_vert;
        pipeDesc.fragmentFunction = fn_hud_tex;
        pipeDesc.colorAttachments[0].blendingEnabled = YES;
        pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        mtl.hudTexturedPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.hudTexturedPipeline)
            Com_Printf("Pipeline fail: hudTextured — %s\n", [[error localizedDescription] UTF8String]);

        /* HUD solid pipeline */
        pipeDesc.fragmentFunction = fn_hud_sol;
        mtl.hudSolidPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.hudSolidPipeline)
            Com_Printf("Pipeline fail: hudSolid — %s\n", [[error localizedDescription] UTF8String]);

        /* World pipeline (opaque, no blending) */
        pipeDesc.vertexFunction = fn_w_vert;
        pipeDesc.fragmentFunction = fn_w_frag;
        pipeDesc.colorAttachments[0].blendingEnabled = NO;
        mtl.worldPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.worldPipeline)
            Com_Printf("Pipeline fail: world — %s\n", [[error localizedDescription] UTF8String]);

        /* Warp pipeline (water/lava — translucent) */
        pipeDesc.fragmentFunction = fn_w_warp;
        pipeDesc.colorAttachments[0].blendingEnabled = YES;
        mtl.warpPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.warpPipeline)
            Com_Printf("Pipeline fail: warp — %s\n", [[error localizedDescription] UTF8String]);

        /* Alias model pipeline */
        pipeDesc.vertexFunction = fn_a_vert;
        pipeDesc.fragmentFunction = fn_a_frag;
        mtl.aliasPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.aliasPipeline)
            Com_Printf("Pipeline fail: alias — %s\n", [[error localizedDescription] UTF8String]);

        /* Particle pipeline */
        pipeDesc.vertexFunction = fn_p_vert;
        pipeDesc.fragmentFunction = fn_p_frag;
        mtl.particlePipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];

        /* White texture (1x1) */
        unsigned char whitePixels[4] = {255, 255, 255, 255};
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:1 height:1 mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead;
        mtl.whiteTexture = [mtl.device newTextureWithDescriptor:texDesc];
        [mtl.whiteTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                            mipmapLevel:0
                              withBytes:whitePixels
                            bytesPerRow:4];

        mtl.width = 1280;
        mtl.height = 720;
        mtl.virtualWidth = 640;
        mtl.virtualHeight = 360;
        mtl.screenScale = 2.0f;

        /* Publish globals for BSPRenderer / ModelLoader */
        mtl_device_global = mtl.device;
        mtl_worldPipeline = mtl.worldPipeline;
        mtl_warpPipeline = mtl.warpPipeline;
        mtl_samplerState = mtl.nearestSampler;
        mtl_whiteTexture = mtl.whiteTexture;

        /* Initialize subsystems */
        Metal_InitImages(mtl.device);
        Metal_InitLightmaps(mtl.device);
        Mod_Init();

        mtl.initialized = true;
        Com_Printf("Metal renderer initialized\n");
        return true;
    }
}

static void R_Shutdown(void)
{
    mtl.initialized = false;
    Metal_ShutdownImages();
    Mod_FreeAll();
    mtl.device = nil;
    mtl.commandQueue = nil;
    mtl_device_global = nil;
    Com_Printf("Metal renderer shut down\n");
}

static void R_BeginRegistration(char *map)
{
    char fullname[256];

    metal_registration_sequence++;
    Metal_ResetBSPState();

    /* Reset lightmap atlas for the new map.
       Without this, a second map load builds lightmaps
       on top of stale allocation state → black surfaces. */
    Metal_InitLightmaps(mtl.device);

    /* Clear old models so the new BSP is loaded fresh */
    Mod_FreeAll();

    Com_sprintf(fullname, sizeof(fullname), "maps/%s.bsp", map);
    r_worldmodel = Mod_ForName(fullname, true);

    Com_Printf("R_BeginRegistration: loaded %s\n", fullname);
}

static struct model_s *R_RegisterModel(char *name)
{
    model_t *mod = Mod_ForName(name, false);
    if (mod) {
        mod->registration_sequence = metal_registration_sequence;
        /* Ensure all skins are registered */
        if (mod->type == mod_alias) {
            dmdl_t *pheader = (dmdl_t *)mod->extradata;
            if (pheader) {
                for (int i = 0; i < pheader->num_skins; i++) {
                    if (mod->skins[i])
                        mod->skins[i]->registration_sequence = metal_registration_sequence;
                }
            }
        } else if (mod->type == mod_sprite) {
            dsprite_t *sprout = (dsprite_t *)mod->extradata;
            if (sprout) {
                for (int i = 0; i < sprout->numframes; i++) {
                    if (mod->skins[i])
                        mod->skins[i]->registration_sequence = metal_registration_sequence;
                }
            }
        }
    }
    return (struct model_s *)mod;
}

static struct image_s *R_RegisterSkin(char *name)
{
    image_t *img = Metal_FindImage(name, it_skin);
    return (struct image_s *)img;
}

static struct image_s *R_RegisterPic(char *name)
{
    @autoreleasepool {
        char fullname[72];
        if (name[0] != '/' && name[0] != '\\') {
            Com_sprintf(fullname, sizeof(fullname), "pics/%s.pcx", name);
        } else {
            strncpy(fullname, name + 1, sizeof(fullname) - 1);
            fullname[sizeof(fullname) - 1] = 0;
        }

        image_t *img = Metal_FindImage(fullname, it_pic);
        return (struct image_s *)img;
    }
}

static void R_SetSky(char *name, float rotate, vec3_t axis)
{
    Com_DPrintf("R_SetSky: %s\n", name);
    /* TODO: Load 6 sky textures */
}

static void R_EndRegistration(void)
{
    Metal_FreeUnusedImages();
}

/* ================================================================ */
#pragma mark - MD2 Alias Model Rendering
/* ================================================================ */

#define NUMVERTEXNORMALS 162
static float r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "../../ref_gl/anorms.h"
};

static void Metal_DrawAliasModel(entity_t *e, Q2FrameUniforms *uniforms)
{
    model_t *mod = (model_t *)e->model;
    if (!mod || mod->type != mod_alias) return;

    dmdl_t *paliashdr = (dmdl_t *)mod->extradata;
    if (!paliashdr) return;

    /* Validate frame indices */
    int curFrame = e->frame;
    int oldFrame = e->oldframe;
    if (curFrame >= paliashdr->num_frames || curFrame < 0) curFrame = 0;
    if (oldFrame >= paliashdr->num_frames || oldFrame < 0) oldFrame = 0;

    /* Get frame data */
    daliasframe_t *frame = (daliasframe_t *)((byte *)paliashdr +
        paliashdr->ofs_frames + curFrame * paliashdr->framesize);
    daliasframe_t *oldframe = (daliasframe_t *)((byte *)paliashdr +
        paliashdr->ofs_frames + oldFrame * paliashdr->framesize);

    /* Compute lerp parameters — lerp positions on CPU like the GL renderer.
       The GL renderer applies frame scale/translate on CPU; we do the same. */
    float backlerp = e->backlerp;
    float frontlerp = 1.0f - backlerp;

    /* Compute origin interpolation delta projected into entity axes */
    vec3_t delta, vectors[3], move;
    VectorSubtract(e->oldorigin, e->origin, delta);
    AngleVectors(e->angles, vectors[0], vectors[1], vectors[2]);

    move[0] = DotProduct(delta, vectors[0]);
    move[1] = -DotProduct(delta, vectors[1]);
    move[2] = DotProduct(delta, vectors[2]);

    VectorAdd(move, oldframe->translate, move);
    for (int i = 0; i < 3; i++)
        move[i] = backlerp * move[i] + frontlerp * frame->translate[i];

    float frontv[3], backv[3];
    for (int i = 0; i < 3; i++) {
        frontv[i] = frontlerp * frame->scale[i];
        backv[i] = backlerp * oldframe->scale[i];
    }

    /* Lerp all vertices on CPU */
    dtrivertx_t *v = frame->verts;
    dtrivertx_t *ov = oldframe->verts;
    int numVerts = paliashdr->num_xyz;

    /* Allocate lerped position + normal arrays (max ~4096 verts in Q2 MD2) */
    float lerpedPos[numVerts][3];
    for (int i = 0; i < numVerts; i++) {
        lerpedPos[i][0] = move[0] + ov[i].v[0] * backv[0] + v[i].v[0] * frontv[0];
        lerpedPos[i][1] = move[1] + ov[i].v[1] * backv[1] + v[i].v[1] * frontv[1];
        lerpedPos[i][2] = move[2] + ov[i].v[2] * backv[2] + v[i].v[2] * frontv[2];
    }

    /* Select skin texture */
    image_t *skin = NULL;
    if (e->skin) {
        skin = (image_t *)e->skin;
    } else {
        int skinnum = e->skinnum;
        if (skinnum >= MAX_MD2SKINS || skinnum < 0) skinnum = 0;
        skin = mod->skins[skinnum];
        if (!skin) skin = mod->skins[0];
    }
    if (!skin || !skin->texture) return;

    /* Build model matrix from entity origin + angles */
    float yaw   = e->angles[1] * (M_PI / 180.0f);
    float pitch = e->angles[0] * (M_PI / 180.0f);
    float roll  = e->angles[2] * (M_PI / 180.0f);

    /* Quake 2 rotation order: yaw around Z, pitch around Y, roll around X */
    float cy = cosf(yaw), sy = sinf(yaw);
    float cp = cosf(pitch), sp = sinf(pitch);
    float cr = cosf(roll), sr = sinf(roll);

    simd_float4x4 modelMatrix = {{
        { cy*cp,                     sy*cp,                    -sp,    0},
        { cy*sp*sr - sy*cr,          sy*sp*sr + cy*cr,          cp*sr, 0},
        { cy*sp*cr + sy*sr,          sy*sp*cr - cy*sr,          cp*cr, 0},
        { e->origin[0],              e->origin[1],              e->origin[2], 1},
    }};

    /* Walk the glcmds list to build triangle list.
       glcmds format: count (+fan/-strip), then count*(s, t, index) triples, repeat until 0 */
    int *order = (int *)((byte *)paliashdr + paliashdr->ofs_glcmds);

    /* Upper bound on triangles: num_tris from the header */
    int maxTriVerts = paliashdr->num_tris * 3;
    Q2AliasVertex *triVerts = malloc(sizeof(Q2AliasVertex) * maxTriVerts);
    if (!triVerts) return;
    int triVertCount = 0;

    while (1) {
        int count = *order++;
        if (!count) break;

        qboolean isFan = false;
        if (count < 0) {
            count = -count;
            isFan = true;
        }

        /* Read all vertices for this strip/fan */
        typedef struct { float s, t; int index; } glcmd_vert_t;
        glcmd_vert_t cmdVerts[count];
        for (int i = 0; i < count; i++) {
            cmdVerts[i].s = ((float *)order)[0];
            cmdVerts[i].t = ((float *)order)[1];
            cmdVerts[i].index = order[2];
            order += 3;
        }

        /* Convert strip/fan to individual triangles */
        for (int i = 0; i < count - 2; i++) {
            if (triVertCount + 3 > maxTriVerts) break;

            int idx0, idx1, idx2;
            if (isFan) {
                idx0 = 0;
                idx1 = i + 1;
                idx2 = i + 2;
            } else {
                /* Alternate winding for strips */
                if (i & 1) {
                    idx0 = i + 1;
                    idx1 = i;
                    idx2 = i + 2;
                } else {
                    idx0 = i;
                    idx1 = i + 1;
                    idx2 = i + 2;
                }
            }

            int indices[3] = { idx0, idx1, idx2 };
            for (int j = 0; j < 3; j++) {
                int ci = indices[j];
                int vi = cmdVerts[ci].index;
                if (vi >= numVerts) vi = 0;

                Q2AliasVertex *av = &triVerts[triVertCount++];
                av->position.x = lerpedPos[vi][0];
                av->position.y = lerpedPos[vi][1];
                av->position.z = lerpedPos[vi][2];
                /* oldPosition not used since we lerp on CPU — set same as position */
                av->oldPosition.x = lerpedPos[vi][0];
                av->oldPosition.y = lerpedPos[vi][1];
                av->oldPosition.z = lerpedPos[vi][2];
                av->texcoord.x = cmdVerts[ci].s;
                av->texcoord.y = cmdVerts[ci].t;
                /* Normal from the lookup table */
                int ni = v[vi].lightnormalindex;
                if (ni >= NUMVERTEXNORMALS) ni = 0;
                av->normal.x = r_avertexnormals[ni][0];
                av->normal.y = r_avertexnormals[ni][1];
                av->normal.z = r_avertexnormals[ni][2];
            }
        }
    }

    if (triVertCount == 0) {
        free(triVerts);
        return;
    }

    /* Set up model uniforms — backlerp=0 since we already lerped on CPU */
    Q2ModelUniforms modelUniforms;
    modelUniforms.modelMatrix = modelMatrix;
    modelUniforms.backlerp = 0.0f; /* Already lerped */
    modelUniforms.alpha = (e->flags & RF_TRANSLUCENT) ? e->alpha : 1.0f;

    /* Draw */
    [mtl.currentEncoder setRenderPipelineState:mtl.aliasPipeline];
    [mtl.currentEncoder setFragmentTexture:skin->texture atIndex:Q2TextureIndexDiffuse];
    [mtl.currentEncoder setFragmentSamplerState:mtl.nearestSampler atIndex:0];

    [mtl.currentEncoder setVertexBytes:triVerts
                                length:sizeof(Q2AliasVertex) * triVertCount
                               atIndex:Q2BufferIndexVertices];
    [mtl.currentEncoder setVertexBytes:uniforms
                                length:sizeof(Q2FrameUniforms)
                               atIndex:Q2BufferIndexFrameUniforms];
    [mtl.currentEncoder setVertexBytes:&modelUniforms
                                length:sizeof(Q2ModelUniforms)
                               atIndex:Q2BufferIndexModelUniforms];
    [mtl.currentEncoder setFragmentBytes:uniforms
                                  length:sizeof(Q2FrameUniforms)
                                 atIndex:Q2BufferIndexFrameUniforms];

    [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                           vertexStart:0
                           vertexCount:triVertCount];

    free(triVerts);
}

/* Draw inline BSP models (doors, lifts, etc.) */
static void Metal_DrawBrushModel(entity_t *e, Q2FrameUniforms *uniforms)
{
    model_t *mod = (model_t *)e->model;
    if (!mod || mod->type != mod_brush) return;

    /* Set up model matrix (translation + rotation) */
    float yaw   = e->angles[1] * (M_PI / 180.0f);
    float pitch = e->angles[0] * (M_PI / 180.0f);
    float roll  = e->angles[2] * (M_PI / 180.0f);

    float cy = cosf(yaw), sy = sinf(yaw);
    float cp = cosf(pitch), sp = sinf(pitch);
    float cr = cosf(roll), sr = sinf(roll);

    simd_float4x4 modelMatrix = {{
        { cy*cp,                     sy*cp,                    -sp,    0},
        { cy*sp*sr - sy*cr,          sy*sp*sr + cy*cr,          cp*sr, 0},
        { cy*sp*cr + sy*sr,          sy*sp*cr - cy*sr,          cp*cr, 0},
        { e->origin[0],              e->origin[1],              e->origin[2], 1},
    }};

    /* Build uniforms with entity model matrix */
    Q2FrameUniforms entUniforms = *uniforms;
    entUniforms.modelMatrix = modelMatrix;

    /* Switch to world pipeline */
    [mtl.currentEncoder setRenderPipelineState:mtl.worldPipeline];
    [mtl.currentEncoder setFragmentSamplerState:mtl.nearestSampler atIndex:0];

    /* Bind default lightmap */
    if (mtl.whiteTexture) {
        [mtl.currentEncoder setFragmentTexture:mtl.whiteTexture atIndex:Q2TextureIndexLightmap];
    }

    [mtl.currentEncoder setVertexBytes:&entUniforms length:sizeof(Q2FrameUniforms)
                               atIndex:Q2BufferIndexFrameUniforms];
    [mtl.currentEncoder setFragmentBytes:&entUniforms length:sizeof(Q2FrameUniforms)
                                 atIndex:Q2BufferIndexFrameUniforms];

    /* Draw all surfaces of this inline BSP model */
    msurface_t *surf = mod->surfaces + mod->firstmodelsurface;
    for (int i = 0; i < mod->nummodelsurfaces; i++, surf++) {
        glpoly_t *p = surf->polys;
        if (!p) continue;

        image_t *tex = surf->texinfo->image;
        if (!tex || !tex->texture) continue;

        [mtl.currentEncoder setFragmentTexture:tex->texture atIndex:Q2TextureIndexDiffuse];

        /* Bind actual lightmap if available */
        extern id<MTLTexture> lightmap_textures[];
        extern int num_lightmap_textures;
        if (surf->lightmaptexturenum >= 0 &&
            surf->lightmaptexturenum < num_lightmap_textures &&
            lightmap_textures[surf->lightmaptexturenum]) {
            [mtl.currentEncoder setFragmentTexture:lightmap_textures[surf->lightmaptexturenum]
                                           atIndex:Q2TextureIndexLightmap];
        }

        int numVerts = p->numverts;
        int numTris = numVerts - 2;
        if (numTris <= 0) continue;

        Q2WorldVertex triVerts[numTris * 3];
        for (int t = 0; t < numTris; t++) {
            for (int k = 0; k < 3; k++) {
                int vi = (k == 0) ? 0 : t + k;
                triVerts[t * 3 + k] = (Q2WorldVertex){
                    {p->verts[vi][0], p->verts[vi][1], p->verts[vi][2]},
                    {p->verts[vi][3], p->verts[vi][4]},
                    {p->verts[vi][5], p->verts[vi][6]}
                };
            }
        }

        [mtl.currentEncoder setVertexBytes:triVerts
                                    length:sizeof(Q2WorldVertex) * numTris * 3
                                   atIndex:Q2BufferIndexVertices];
        [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                               vertexStart:0
                               vertexCount:numTris * 3];
    }
}

/* Draw all entities in the refdef */
static void Metal_DrawEntitiesOnList(refdef_t *fd, Q2FrameUniforms *uniforms)
{
    if (!fd->num_entities) return;

    /* Pass 1: opaque entities */
    for (int i = 0; i < fd->num_entities; i++) {
        entity_t *e = &fd->entities[i];
        if (e->flags & RF_TRANSLUCENT)
            continue;
        if (e->flags & RF_BEAM)
            continue; /* TODO: beam rendering */

        model_t *mod = (model_t *)e->model;
        if (!mod) continue;

        switch (mod->type) {
            case mod_alias:
                Metal_DrawAliasModel(e, uniforms);
                break;
            case mod_brush:
                Metal_DrawBrushModel(e, uniforms);
                break;
            case mod_sprite:
                /* TODO: sprite rendering */
                break;
            default:
                break;
        }
    }

    /* Pass 2: translucent entities (depth write disabled) */
    MTLDepthStencilDescriptor *transDesc = [[MTLDepthStencilDescriptor alloc] init];
    transDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    transDesc.depthWriteEnabled = NO;
    id<MTLDepthStencilState> transDepth = [mtl.device newDepthStencilStateWithDescriptor:transDesc];
    [mtl.currentEncoder setDepthStencilState:transDepth];

    for (int i = 0; i < fd->num_entities; i++) {
        entity_t *e = &fd->entities[i];
        if (!(e->flags & RF_TRANSLUCENT))
            continue;
        if (e->flags & RF_BEAM)
            continue;

        model_t *mod = (model_t *)e->model;
        if (!mod) continue;

        switch (mod->type) {
            case mod_alias:
                Metal_DrawAliasModel(e, uniforms);
                break;
            case mod_brush:
                Metal_DrawBrushModel(e, uniforms);
                break;
            default:
                break;
        }
    }

    /* Restore depth write */
    [mtl.currentEncoder setDepthStencilState:mtl.depthEnabled];
}

/* ================================================================ */
#pragma mark - Particle Rendering
/* ================================================================ */

static void Metal_DrawParticles(refdef_t *fd, Q2FrameUniforms *uniforms)
{
    if (!fd->num_particles || !fd->particles) return;

    int count = fd->num_particles;
    Q2ParticleVertex *pverts = malloc(sizeof(Q2ParticleVertex) * count);
    if (!pverts) return;

    for (int i = 0; i < count; i++) {
        particle_t *p = &fd->particles[i];
        unsigned color = d_8to24table[p->color & 0xFF];

        pverts[i].position.x = p->origin[0];
        pverts[i].position.y = p->origin[1];
        pverts[i].position.z = p->origin[2];
        pverts[i].color.x = (color & 0xFF) / 255.0f;
        pverts[i].color.y = ((color >> 8) & 0xFF) / 255.0f;
        pverts[i].color.z = ((color >> 16) & 0xFF) / 255.0f;
        pverts[i].color.w = p->alpha;
        pverts[i].size = 1.5f;
    }

    /* Disable depth write for particles */
    MTLDepthStencilDescriptor *pDesc = [[MTLDepthStencilDescriptor alloc] init];
    pDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    pDesc.depthWriteEnabled = NO;
    id<MTLDepthStencilState> particleDepth = [mtl.device newDepthStencilStateWithDescriptor:pDesc];

    [mtl.currentEncoder setRenderPipelineState:mtl.particlePipeline];
    [mtl.currentEncoder setDepthStencilState:particleDepth];

    [mtl.currentEncoder setVertexBytes:pverts
                                length:sizeof(Q2ParticleVertex) * count
                               atIndex:0];
    [mtl.currentEncoder setVertexBytes:uniforms
                                length:sizeof(Q2FrameUniforms)
                               atIndex:1];

    [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypePoint
                           vertexStart:0
                           vertexCount:count];

    /* Restore depth state */
    [mtl.currentEncoder setDepthStencilState:mtl.depthEnabled];

    free(pverts);
}

/* ================================================================ */
#pragma mark - 3D Rendering
/* ================================================================ */

static void R_RenderFrame(refdef_t *fd)
{
    if (!mtl.currentEncoder) return;

    /* Store refdef for BSPRenderer */
    r_newrefdef = *fd;

    /* Build matrices */
    float aspect = (float)fd->width / (float)fd->height;
    simd_float4x4 proj = Metal_PerspectiveMatrix(fd->fov_y, aspect, 4.0f, 4096.0f);
    simd_float4x4 view = Metal_ViewMatrix(fd->vieworg, fd->viewangles);

    /* Fill frame uniforms */
    Q2FrameUniforms uniforms;
    uniforms.projectionMatrix = proj;
    uniforms.viewMatrix = view;
    uniforms.modelMatrix = matrix_identity_float4x4;
    uniforms.viewOrigin.x = fd->vieworg[0];
    uniforms.viewOrigin.y = fd->vieworg[1];
    uniforms.viewOrigin.z = fd->vieworg[2];
    uniforms.time = (float)fd->time * 0.001f;
    uniforms.gamma = 1.0f;

    /* Set viewport to the 3D view area.
       refdef coords are in virtual (point) space — scale to pixels. */
    float s = mtl.screenScale;
    [mtl.currentEncoder setViewport:(MTLViewport){
        fd->x * s, fd->y * s, fd->width * s, fd->height * s, 0, 1
    }];

    /* 3D rendering with depth test, no hardware culling
       (BSP renderer does its own back-face culling in software) */
    [mtl.currentEncoder setDepthStencilState:mtl.depthEnabled];
    [mtl.currentEncoder setCullMode:MTLCullModeNone];

    /* Update global encoder for BSPRenderer */
    mtl_encoder_global = mtl.currentEncoder;

    /* Draw BSP world */
    if (r_worldmodel) {
        Metal_SetupFrame(fd);
        Metal_DrawWorld(mtl.currentEncoder, &uniforms);
    }

    /* Draw entities (MD2 models, brush models, sprites) */
    Metal_DrawEntitiesOnList(fd, &uniforms);

    /* Draw particles */
    Metal_DrawParticles(fd, &uniforms);

    /* Draw translucent surfaces last */
    if (r_worldmodel) {
        Metal_DrawAlphaSurfaces(mtl.currentEncoder, &uniforms);
    }

    /* Reset viewport to full screen for HUD */
    [mtl.currentEncoder setViewport:(MTLViewport){
        0, 0, mtl.width, mtl.height, 0, 1
    }];
}

/* ================================================================ */
#pragma mark - 2D Drawing (HUD / Menu)
/* ================================================================ */

static void R_DrawGetPicSize(int *w, int *h, char *name)
{
    image_t *img = (image_t *)R_RegisterPic(name);
    if (!img) {
        *w = *h = -1;
        return;
    }
    *w = img->width;
    *h = img->height;
}

/* Forward declaration */
static void R_DrawStretchPic(int x, int y, int w, int h, char *name);

static void R_DrawPic(int x, int y, char *name)
{
    image_t *img = (image_t *)R_RegisterPic(name);
    if (!img) return;
    R_DrawStretchPic(x, y, img->width, img->height, name);
}

static void R_DrawStretchPic(int x, int y, int w, int h, char *name)
{
    @autoreleasepool {
        image_t *img = (image_t *)R_RegisterPic(name);
        if (!img || !img->texture) return;

        id<MTLTexture> tex = img->texture;

        if (mtl.currentHUDTexture && mtl.currentHUDTexture != tex)
            Metal_FlushHUDBatch();
        mtl.currentHUDTexture = tex;

        float x0 = (float)x, y0 = (float)y;
        float x1 = x0 + w, y1 = y0 + h;
        packed_float4 white = {1, 1, 1, 1};

        if (mtl.hudVertexCount + 6 > 65536)
            Metal_FlushHUDBatch();

        Q2HUDVertex *v = &mtl.hudVertices[mtl.hudVertexCount];
        v[0] = (Q2HUDVertex){{x0, y0}, {0, 0}, white};
        v[1] = (Q2HUDVertex){{x1, y0}, {1, 0}, white};
        v[2] = (Q2HUDVertex){{x0, y1}, {0, 1}, white};
        v[3] = (Q2HUDVertex){{x1, y0}, {1, 0}, white};
        v[4] = (Q2HUDVertex){{x1, y1}, {1, 1}, white};
        v[5] = (Q2HUDVertex){{x0, y1}, {0, 1}, white};
        mtl.hudVertexCount += 6;
    }
}

static void R_DrawChar(int x, int y, int c)
{
    c &= 255;
    if (c == ' ' || c == 0) return;

    if (!mtl.concharsImage) {
        mtl.concharsImage = Metal_FindImage("pics/conchars.pcx", it_pic);
        if (!mtl.concharsImage) return;
    }

    id<MTLTexture> tex = mtl.concharsImage->texture;
    if (!tex) return;

    if (mtl.currentHUDTexture && mtl.currentHUDTexture != tex)
        Metal_FlushHUDBatch();
    mtl.currentHUDTexture = tex;

    int row = c >> 4;
    int col = c & 15;
    float s0 = col * (1.0f / 16.0f);
    float t0 = row * (1.0f / 16.0f);
    float s1 = s0 + (1.0f / 16.0f);
    float t1 = t0 + (1.0f / 16.0f);

    float x0 = (float)x, y0 = (float)y;
    float x1 = x0 + 8, y1 = y0 + 8;
    packed_float4 white = {1, 1, 1, 1};

    if (mtl.hudVertexCount + 6 > 65536)
        Metal_FlushHUDBatch();

    Q2HUDVertex *v = &mtl.hudVertices[mtl.hudVertexCount];
    v[0] = (Q2HUDVertex){{x0, y0}, {s0, t0}, white};
    v[1] = (Q2HUDVertex){{x1, y0}, {s1, t0}, white};
    v[2] = (Q2HUDVertex){{x0, y1}, {s0, t1}, white};
    v[3] = (Q2HUDVertex){{x1, y0}, {s1, t0}, white};
    v[4] = (Q2HUDVertex){{x1, y1}, {s1, t1}, white};
    v[5] = (Q2HUDVertex){{x0, y1}, {s0, t1}, white};
    mtl.hudVertexCount += 6;
}

static void R_DrawTileClear(int x, int y, int w, int h, char *name)
{
    R_DrawStretchPic(x, y, w, h, name);
}

static void R_DrawFill(int x, int y, int w, int h, int c)
{
    @autoreleasepool {
        Metal_FlushHUDBatch();
        if (!mtl.currentEncoder) return;

        unsigned color = d_8to24table[c & 255];
        float r = (color & 0xFF) / 255.0f;
        float g = ((color >> 8) & 0xFF) / 255.0f;
        float b = ((color >> 16) & 0xFF) / 255.0f;

        float x0 = (float)x, y0 = (float)y;
        float x1 = x0 + w, y1 = y0 + h;
        packed_float4 col = {r, g, b, 1.0f};

        Q2HUDVertex vertices[6] = {
            {{x0, y0}, {0, 0}, col},
            {{x1, y0}, {0, 0}, col},
            {{x0, y1}, {0, 0}, col},
            {{x1, y0}, {0, 0}, col},
            {{x1, y1}, {0, 0}, col},
            {{x0, y1}, {0, 0}, col},
        };

        [mtl.currentEncoder setRenderPipelineState:mtl.hudSolidPipeline];
        [mtl.currentEncoder setDepthStencilState:mtl.depthDisabled];
        [mtl.currentEncoder setCullMode:MTLCullModeNone]; /* 2D: ortho Y-flip reverses winding */

        float vw = (float)mtl.virtualWidth;
        float vh = (float)mtl.virtualHeight;
        simd_float4x4 ortho = {
            .columns[0] = {2.0f / vw, 0, 0, 0},
            .columns[1] = {0, -2.0f / vh, 0, 0},
            .columns[2] = {0, 0, 1, 0},
            .columns[3] = {-1, 1, 0, 1},
        };

        [mtl.currentEncoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [mtl.currentEncoder setVertexBytes:&ortho length:sizeof(ortho) atIndex:1];
        [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
}

static void R_DrawFadeScreen(void)
{
    R_DrawFill(0, 0, mtl.virtualWidth, mtl.virtualHeight, 0);
}

static void R_DrawStretchRaw(int x, int y, int w, int h,
                              int cols, int rows, byte *data)
{
    /* Cinematic frames — create a temporary texture from raw paletted data */
    @autoreleasepool {
        if (!mtl.currentEncoder || !data) return;

        byte *rgba = malloc(cols * rows * 4);
        if (!rgba) return;

        for (int i = 0; i < cols * rows; i++) {
            unsigned color = d_8to24table[data[i]];
            rgba[i * 4 + 0] = color & 0xFF;
            rgba[i * 4 + 1] = (color >> 8) & 0xFF;
            rgba[i * 4 + 2] = (color >> 16) & 0xFF;
            rgba[i * 4 + 3] = 255;
        }

        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:cols height:rows mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;

        id<MTLTexture> tex = [mtl.device newTextureWithDescriptor:desc];
        [tex replaceRegion:MTLRegionMake2D(0, 0, cols, rows)
               mipmapLevel:0
                 withBytes:rgba
               bytesPerRow:cols * 4];
        free(rgba);

        /* Draw as a stretched quad */
        Metal_FlushHUDBatch();
        mtl.currentHUDTexture = tex;

        float x0 = (float)x, y0 = (float)y;
        float x1 = x0 + w, y1 = y0 + h;
        packed_float4 white = {1, 1, 1, 1};

        Q2HUDVertex *v = &mtl.hudVertices[0];
        v[0] = (Q2HUDVertex){{x0, y0}, {0, 0}, white};
        v[1] = (Q2HUDVertex){{x1, y0}, {1, 0}, white};
        v[2] = (Q2HUDVertex){{x0, y1}, {0, 1}, white};
        v[3] = (Q2HUDVertex){{x1, y0}, {1, 0}, white};
        v[4] = (Q2HUDVertex){{x1, y1}, {1, 1}, white};
        v[5] = (Q2HUDVertex){{x0, y1}, {0, 1}, white};
        mtl.hudVertexCount = 6;
        Metal_FlushHUDBatch();
    }
}

static void R_CinematicSetPalette(const unsigned char *palette)
{
    /* Update palette for cinematic playback */
    if (palette) {
        for (int i = 0; i < 256; i++) {
            unsigned r = palette[i * 3 + 0];
            unsigned g = palette[i * 3 + 1];
            unsigned b = palette[i * 3 + 2];
            d_8to24table[i] = r | (g << 8) | (b << 16) | (255 << 24);
        }
    } else {
        /* Restore original palette */
        Metal_LoadPalette();
    }
}

/* ================================================================ */
#pragma mark - Frame Management
/* ================================================================ */

static void R_BeginFrame(float camera_separation)
{
    @autoreleasepool {
        if (!mtl.initialized || !mtl.metalLayer) return;

        /* Guard: the layer must have a valid non-zero drawableSize
           before we can acquire a drawable. */
        CGSize layerSize = mtl.metalLayer.drawableSize;
        if (layerSize.width < 1 || layerSize.height < 1) return;

        mtl.currentDrawable = [mtl.metalLayer nextDrawable];
        if (!mtl.currentDrawable) return;

        CGSize drawableSize = mtl.metalLayer.drawableSize;
        mtl.width = (int)drawableSize.width;
        mtl.height = (int)drawableSize.height;

        /* Compute virtual dimensions from layer's content scale.
           viddef is set to point dimensions by vid_ios.m;
           the ortho projection must match those coordinates. */
        CGFloat scale = mtl.metalLayer.contentsScale;
        if (scale < 1.0) scale = 1.0;
        mtl.screenScale = (float)scale;
        mtl.virtualWidth = (int)(drawableSize.width / scale);
        mtl.virtualHeight = (int)(drawableSize.height / scale);

        /* Ensure depth texture matches */
        if (!mtl.depthTexture ||
            [mtl.depthTexture width] != (NSUInteger)mtl.width ||
            [mtl.depthTexture height] != (NSUInteger)mtl.height) {

            MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                width:mtl.width height:mtl.height mipmapped:NO];
            depthDesc.usage = MTLTextureUsageRenderTarget;
            depthDesc.storageMode = MTLStorageModePrivate;
            mtl.depthTexture = [mtl.device newTextureWithDescriptor:depthDesc];
        }

        mtl.currentCommandBuffer = [mtl.commandQueue commandBuffer];

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = mtl.currentDrawable.texture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        rpd.depthAttachment.texture = mtl.depthTexture;
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
        rpd.depthAttachment.clearDepth = 1.0;

        mtl.currentEncoder = [mtl.currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
        [mtl.currentEncoder setViewport:(MTLViewport){
            0, 0, drawableSize.width, drawableSize.height, 0, 1
        }];
        [mtl.currentEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [mtl.currentEncoder setCullMode:MTLCullModeBack];

        mtl.hudVertexCount = 0;
        mtl.currentHUDTexture = nil;
    }
}

static void Metal_FlushHUDBatch(void)
{
    if (mtl.hudVertexCount == 0 || !mtl.currentEncoder) return;

    @autoreleasepool {
        [mtl.currentEncoder setRenderPipelineState:mtl.hudTexturedPipeline];
        [mtl.currentEncoder setDepthStencilState:mtl.depthDisabled];
        [mtl.currentEncoder setCullMode:MTLCullModeNone]; /* 2D: ortho Y-flip reverses winding */

        /* Use virtual (point) dimensions so HUD coordinates from game code
           map correctly to the full viewport. */
        float vw = (float)mtl.virtualWidth;
        float vh = (float)mtl.virtualHeight;
        simd_float4x4 ortho = {
            .columns[0] = {2.0f / vw, 0, 0, 0},
            .columns[1] = {0, -2.0f / vh, 0, 0},
            .columns[2] = {0, 0, 1, 0},
            .columns[3] = {-1, 1, 0, 1},
        };

        [mtl.currentEncoder setVertexBytes:mtl.hudVertices
                                    length:mtl.hudVertexCount * sizeof(Q2HUDVertex)
                                   atIndex:0];
        [mtl.currentEncoder setVertexBytes:&ortho length:sizeof(ortho) atIndex:1];
        [mtl.currentEncoder setFragmentTexture:mtl.currentHUDTexture atIndex:0];
        [mtl.currentEncoder setFragmentSamplerState:mtl.nearestSampler atIndex:0];
        [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                               vertexStart:0
                               vertexCount:mtl.hudVertexCount];

        mtl.hudVertexCount = 0;
        mtl.currentHUDTexture = nil;
    }
}

static void R_EndFrame(void)
{
    @autoreleasepool {
        if (!mtl.currentEncoder) return;

        Metal_FlushHUDBatch();

        [mtl.currentEncoder endEncoding];
        mtl.currentEncoder = nil;
        mtl_encoder_global = nil;

        if (mtl.currentDrawable) {
            [mtl.currentCommandBuffer presentDrawable:mtl.currentDrawable];
        }

        [mtl.currentCommandBuffer commit];
        mtl.currentCommandBuffer = nil;
        mtl.currentDrawable = nil;
    }
}

static void R_AppActivate(qboolean activate)
{
    /* Nothing needed on iOS */
}

/* ================================================================ */
#pragma mark - GetRefAPI (entry point)
/* ================================================================ */

refexport_t Metal_GetRefAPI(refimport_t rimp)
{
    refexport_t re;

    mtl.ri = rimp;

    re.api_version = API_VERSION;
    re.Init = R_Init;
    re.Shutdown = R_Shutdown;
    re.BeginRegistration = R_BeginRegistration;
    re.RegisterModel = R_RegisterModel;
    re.RegisterSkin = R_RegisterSkin;
    re.RegisterPic = R_RegisterPic;
    re.SetSky = R_SetSky;
    re.EndRegistration = R_EndRegistration;
    re.RenderFrame = R_RenderFrame;
    re.DrawGetPicSize = R_DrawGetPicSize;
    re.DrawPic = R_DrawPic;
    re.DrawStretchPic = R_DrawStretchPic;
    re.DrawChar = R_DrawChar;
    re.DrawTileClear = R_DrawTileClear;
    re.DrawFill = R_DrawFill;
    re.DrawFadeScreen = R_DrawFadeScreen;
    re.DrawStretchRaw = R_DrawStretchRaw;
    re.CinematicSetPalette = R_CinematicSetPalette;
    re.BeginFrame = R_BeginFrame;
    re.EndFrame = R_EndFrame;
    re.AppActivate = R_AppActivate;

    return re;
}

/* ================================================================ */
#pragma mark - Metal Layer access (called from Swift)
/* ================================================================ */

void IOS_SetMetalLayer(void *layer)
{
    mtl.metalLayer = (__bridge CAMetalLayer *)layer;

    /* Full configuration — device may not be set yet if called before
       R_Init(), so only configure properties that don't need it. */
    mtl.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtl.metalLayer.framebufferOnly = YES;

    if (mtl.device) {
        mtl.metalLayer.device = mtl.device;
    }

    /* Ensure the layer has a valid drawableSize from its bounds */
    CGSize bounds = mtl.metalLayer.bounds.size;
    CGFloat scale = mtl.metalLayer.contentsScale;
    if (bounds.width > 0 && bounds.height > 0) {
        mtl.metalLayer.drawableSize = CGSizeMake(bounds.width * scale,
                                                  bounds.height * scale);
        Com_Printf("IOS_SetMetalLayer: %.0fx%.0f (scale %.1f)\n",
                    bounds.width * scale, bounds.height * scale, scale);
    }
}

CAMetalLayer *Metal_GetLayer(void)
{
    return mtl.metalLayer;
}
