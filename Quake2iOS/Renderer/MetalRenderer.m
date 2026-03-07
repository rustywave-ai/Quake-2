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
#pragma mark - Sky State
/* ================================================================ */

static char     skyname[MAX_QPATH];
static float    skyrotate;
static vec3_t   skyaxis;
static image_t  *sky_images[6];

#ifndef SIDE_FRONT
#define SIDE_FRONT  0
#define SIDE_BACK   1
#define SIDE_ON     2
#endif

/* Sky clipping planes (from gl_warp.c) */
static vec3_t skyclip[6] = {
    {1,1,0}, {1,-1,0}, {0,-1,1}, {0,1,1}, {1,0,1}, {-1,0,1}
};

/* Map from sky face → 3D coordinate axis.  1 = s, 2 = t, 3 = 2048 */
static int st_to_vec[6][3] = {
    { 3,-1, 2}, {-3, 1, 2},
    { 1, 3, 2}, {-1,-3, 2},
    {-2,-1, 3}, { 2,-1,-3}
};

/* Map from 3D coordinate → sky face s/t.  s = [0]/[2], t = [1]/[2] */
static int vec_to_st[6][3] = {
    {-2, 3, 1}, { 2, 3,-1},
    { 1, 3, 2}, {-1, 3,-2},
    {-2,-1, 3}, {-2, 1,-3}
};

static float skymins[2][6], skymaxs[2][6];
static float sky_min, sky_max;

/* Texture order for the 6 faces */
static int skytexorder[6] = {0, 2, 1, 3, 4, 5};

/* Suffix names for sky face images: rt, bk, lf, ft, up, dn */
static char *sky_suf[6] = {"rt", "bk", "lf", "ft", "up", "dn"};

/* Sky surfaces collected during BSP traversal */
#define MAX_SKY_SURFACES 256
static msurface_t *sky_surfaces[MAX_SKY_SURFACES];
static int num_sky_surfaces = 0;

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
    id<MTLRenderPipelineState> skyPipeline;
    id<MTLRenderPipelineState> beamPipeline;

    /* Depth stencil */
    id<MTLDepthStencilState> depthEnabled;
    id<MTLDepthStencilState> depthDisabled;
    id<MTLDepthStencilState> depthReadOnly;

    /* Sampler */
    id<MTLSamplerState> nearestSampler;
    id<MTLSamplerState> linearSampler;
    id<MTLSamplerState> clampSampler;

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

/* Helper: bind vertex data — uses setVertexBytes for ≤4KB, MTLBuffer for larger */
static void Metal_SetVertexData(id<MTLRenderCommandEncoder> encoder,
                                const void *data, NSUInteger length,
                                NSUInteger index)
{
    if (length <= 4096) {
        [encoder setVertexBytes:data length:length atIndex:index];
    } else {
        id<MTLBuffer> buf = [mtl.device newBufferWithBytes:data
                                                    length:length
                                                   options:MTLResourceStorageModeShared];
        [encoder setVertexBuffer:buf offset:0 atIndex:index];
    }
}

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

        /* Depth read-only (test but don't write — for sky behind world) */
        depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
        depthDesc.depthWriteEnabled = NO;
        mtl.depthReadOnly = [mtl.device newDepthStencilStateWithDescriptor:depthDesc];

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

        /* Sky pipeline (opaque, uses world vertex + sky fragment) */
        id<MTLFunction> fn_sky_frag = [mtl.shaderLibrary newFunctionWithName:@"world_sky_fragment"];
        pipeDesc.vertexFunction = fn_w_vert;
        pipeDesc.fragmentFunction = fn_sky_frag;
        pipeDesc.colorAttachments[0].blendingEnabled = NO;
        mtl.skyPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.skyPipeline)
            Com_Printf("Pipeline fail: sky — %s\n", [[error localizedDescription] UTF8String]);

        /* Beam pipeline (untextured, colored, alpha blended) */
        id<MTLFunction> fn_beam_vert = [mtl.shaderLibrary newFunctionWithName:@"beam_vertex"];
        id<MTLFunction> fn_beam_frag = [mtl.shaderLibrary newFunctionWithName:@"beam_fragment"];
        pipeDesc.vertexFunction = fn_beam_vert;
        pipeDesc.fragmentFunction = fn_beam_frag;
        pipeDesc.colorAttachments[0].blendingEnabled = YES;
        pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        mtl.beamPipeline = [mtl.device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
        if (!mtl.beamPipeline)
            Com_Printf("Pipeline fail: beam — %s\n", [[error localizedDescription] UTF8String]);

        /* Clamp-to-edge sampler for sky textures (avoids seams) */
        samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        mtl.clampSampler = [mtl.device newSamplerStateWithDescriptor:samplerDesc];

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
    strncpy(skyname, name, sizeof(skyname) - 1);
    skyrotate = rotate;
    VectorCopy(axis, skyaxis);

    for (int i = 0; i < 6; i++) {
        char pathname[MAX_QPATH];

        /* Try TGA first, then PCX */
        Com_sprintf(pathname, sizeof(pathname), "env/%s%s.tga", skyname, sky_suf[i]);
        sky_images[i] = Metal_FindImage(pathname, it_sky);
        if (!sky_images[i]) {
            Com_sprintf(pathname, sizeof(pathname), "env/%s%s.pcx", skyname, sky_suf[i]);
            sky_images[i] = Metal_FindImage(pathname, it_sky);
        }
        if (!sky_images[i]) {
            Com_Printf("R_SetSky: could not load %s%s\n", skyname, sky_suf[i]);
        }
    }

    sky_min = 1.0f / 512.0f;
    sky_max = 511.0f / 512.0f;

    Com_Printf("R_SetSky: %s (rotate %.0f)\n", name, rotate);
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

    Metal_SetVertexData(mtl.currentEncoder, triVerts,
                        sizeof(Q2AliasVertex) * triVertCount,
                        Q2BufferIndexVertices);

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

        Metal_SetVertexData(mtl.currentEncoder, triVerts,
                            sizeof(Q2WorldVertex) * numTris * 3,
                            Q2BufferIndexVertices);
        [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                               vertexStart:0
                               vertexCount:numTris * 3];
    }
}

/* ================================================================ */
#pragma mark - Sprite Rendering
/* ================================================================ */

static void Metal_DrawSpriteModel(entity_t *e, Q2FrameUniforms *uniforms)
{
    model_t *mod = (model_t *)e->model;
    if (!mod || mod->type != mod_sprite) return;

    dsprite_t *psprite = (dsprite_t *)mod->extradata;
    if (!psprite) return;

    int framenum = e->frame % psprite->numframes;
    dsprframe_t *frame = &psprite->frames[framenum];

    /* Get skin texture for this frame */
    image_t *skin = mod->skins[framenum];
    if (!skin || !skin->texture) return;

    float alpha = (e->flags & RF_TRANSLUCENT) ? e->alpha : 1.0f;

    /* Compute view vectors from current refdef angles for billboarding */
    vec3_t vup, vright, vpn;
    AngleVectors(r_newrefdef.viewangles, vpn, vright, vup);

    /* Build billboard quad vertices (4 corners → 2 triangles)
       Sprite is positioned at e->origin, offset by frame->origin_x/y,
       then expanded by frame->width/height along view-aligned axes. */
    vec3_t point;
    Q2AliasVertex quad[6]; /* 2 triangles = 6 vertices */

    /* Compute the 4 corners of the sprite quad */
    vec3_t corners[4];

    /* Bottom-left: (0,1) */
    VectorMA(e->origin, -(float)frame->origin_y, vup, point);
    VectorMA(point, -(float)frame->origin_x, vright, corners[0]);

    /* Top-left: (0,0) */
    VectorMA(e->origin, (float)(frame->height - frame->origin_y), vup, point);
    VectorMA(point, -(float)frame->origin_x, vright, corners[1]);

    /* Top-right: (1,0) */
    VectorMA(e->origin, (float)(frame->height - frame->origin_y), vup, point);
    VectorMA(point, (float)(frame->width - frame->origin_x), vright, corners[2]);

    /* Bottom-right: (1,1) */
    VectorMA(e->origin, -(float)frame->origin_y, vup, point);
    VectorMA(point, (float)(frame->width - frame->origin_x), vright, corners[3]);

    float uvs[4][2] = {
        {0.0f, 1.0f}, /* bottom-left */
        {0.0f, 0.0f}, /* top-left */
        {1.0f, 0.0f}, /* top-right */
        {1.0f, 1.0f}, /* bottom-right */
    };

    /* Triangle 1: BL, TL, TR */
    int triIdx[6] = {0, 1, 2, 0, 2, 3};
    for (int i = 0; i < 6; i++) {
        int ci = triIdx[i];
        quad[i].position.x = corners[ci][0];
        quad[i].position.y = corners[ci][1];
        quad[i].position.z = corners[ci][2];
        quad[i].oldPosition = quad[i].position;
        quad[i].texcoord.x = uvs[ci][0];
        quad[i].texcoord.y = uvs[ci][1];
        /* Normal pointing at camera — gives full lighting in alias shader */
        quad[i].normal.x = vpn[0];
        quad[i].normal.y = vpn[1];
        quad[i].normal.z = vpn[2];
    }

    /* Use alias pipeline with identity model matrix (positions in world space) */
    Q2ModelUniforms modelUniforms;
    modelUniforms.modelMatrix = matrix_identity_float4x4;
    modelUniforms.backlerp = 0.0f;
    modelUniforms.alpha = alpha;

    [mtl.currentEncoder setRenderPipelineState:mtl.aliasPipeline];
    [mtl.currentEncoder setFragmentTexture:skin->texture atIndex:Q2TextureIndexDiffuse];
    [mtl.currentEncoder setFragmentSamplerState:mtl.nearestSampler atIndex:0];

    [mtl.currentEncoder setVertexBytes:quad
                                length:sizeof(Q2AliasVertex) * 6
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
                           vertexCount:6];
}

/* ================================================================ */
#pragma mark - Beam Rendering
/* ================================================================ */

#define NUM_BEAM_SEGS 6

static void Metal_DrawBeam(entity_t *e, Q2FrameUniforms *uniforms)
{
    vec3_t perpvec;
    vec3_t direction, normalized_direction;
    vec3_t start_points[NUM_BEAM_SEGS], end_points[NUM_BEAM_SEGS];
    vec3_t oldorigin, origin;

    VectorCopy(e->oldorigin, oldorigin);
    VectorCopy(e->origin, origin);

    normalized_direction[0] = direction[0] = oldorigin[0] - origin[0];
    normalized_direction[1] = direction[1] = oldorigin[1] - origin[1];
    normalized_direction[2] = direction[2] = oldorigin[2] - origin[2];

    if (VectorNormalize(normalized_direction) == 0)
        return;

    PerpendicularVector(perpvec, normalized_direction);
    VectorScale(perpvec, e->frame / 2.0f, perpvec);

    for (int i = 0; i < NUM_BEAM_SEGS; i++) {
        RotatePointAroundVector(start_points[i], normalized_direction,
                                perpvec, (360.0f / NUM_BEAM_SEGS) * i);
        VectorAdd(start_points[i], origin, start_points[i]);
        VectorAdd(start_points[i], direction, end_points[i]);
    }

    /* Get color from palette */
    unsigned color = d_8to24table[e->skinnum & 0xFF];
    float r = (color & 0xFF) / 255.0f;
    float g = ((color >> 8) & 0xFF) / 255.0f;
    float b = ((color >> 16) & 0xFF) / 255.0f;
    float a = e->alpha;

    /* Build triangle list from the beam segments.
       Each segment produces 2 triangles (a quad), for 6 segments = 12 tris = 36 verts */
    Q2BeamVertex verts[NUM_BEAM_SEGS * 6]; /* 6 verts per quad (2 triangles) */
    int vertCount = 0;

    for (int i = 0; i < NUM_BEAM_SEGS; i++) {
        int next = (i + 1) % NUM_BEAM_SEGS;

        /* Quad: start[i], end[i], start[next], end[next] → 2 triangles */
        /* Triangle 1: start[i], end[i], start[next] */
        verts[vertCount].position = (packed_float3){start_points[i][0], start_points[i][1], start_points[i][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;

        verts[vertCount].position = (packed_float3){end_points[i][0], end_points[i][1], end_points[i][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;

        verts[vertCount].position = (packed_float3){start_points[next][0], start_points[next][1], start_points[next][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;

        /* Triangle 2: end[i], end[next], start[next] */
        verts[vertCount].position = (packed_float3){end_points[i][0], end_points[i][1], end_points[i][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;

        verts[vertCount].position = (packed_float3){end_points[next][0], end_points[next][1], end_points[next][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;

        verts[vertCount].position = (packed_float3){start_points[next][0], start_points[next][1], start_points[next][2]};
        verts[vertCount].color = (packed_float4){r, g, b, a};
        vertCount++;
    }

    /* Render with beam pipeline, depth read-only (don't occlude other things) */
    [mtl.currentEncoder setRenderPipelineState:mtl.beamPipeline];
    [mtl.currentEncoder setDepthStencilState:mtl.depthReadOnly];

    [mtl.currentEncoder setVertexBytes:verts
                                length:sizeof(Q2BeamVertex) * vertCount
                               atIndex:Q2BufferIndexVertices];
    [mtl.currentEncoder setVertexBytes:uniforms
                                length:sizeof(Q2FrameUniforms)
                               atIndex:Q2BufferIndexFrameUniforms];

    [mtl.currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                           vertexStart:0
                           vertexCount:vertCount];

    /* Restore depth state */
    [mtl.currentEncoder setDepthStencilState:mtl.depthEnabled];
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
        if (e->flags & RF_BEAM) {
            Metal_DrawBeam(e, uniforms);
            continue;
        }

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
                Metal_DrawSpriteModel(e, uniforms);
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
        if (e->flags & RF_BEAM) {
            Metal_DrawBeam(e, uniforms);
            continue;
        }

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
                Metal_DrawSpriteModel(e, uniforms);
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

    Metal_SetVertexData(mtl.currentEncoder, pverts,
                        sizeof(Q2ParticleVertex) * count, 0);
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
#pragma mark - Sky Rendering
/* ================================================================ */

/*
 * Port of gl_warp.c sky rendering.
 *
 * The approach: during BSP traversal, surfaces with SURF_DRAWSKY are
 * collected. We then project those polygons to determine which of the
 * 6 skybox faces are visible and what s/t range to draw. Finally we
 * emit quads for each visible skybox face.
 */

void Metal_AddSkySurface(msurface_t *fa)
{
    if (num_sky_surfaces < MAX_SKY_SURFACES)
        sky_surfaces[num_sky_surfaces++] = fa;
}

void Metal_ClearSkySurfaces(void)
{
    num_sky_surfaces = 0;
}

/* ---- Sky clipping & face determination (from gl_warp.c) ---- */

static int c_sky;

static void DrawSkyPolygon(int nump, vec3_t vecs)
{
    int     i, j;
    vec3_t  v, av;
    float   s, t, dv;
    int     axis;
    float   *vp;

    c_sky++;

    /* Determine which face this polygon maps to */
    VectorCopy(vec3_origin, v);
    for (i = 0, vp = vecs; i < nump; i++, vp += 3)
        VectorAdd(vp, v, v);

    av[0] = fabs(v[0]);
    av[1] = fabs(v[1]);
    av[2] = fabs(v[2]);

    if (av[0] > av[1] && av[0] > av[2])
        axis = (v[0] < 0) ? 1 : 0;
    else if (av[1] > av[2] && av[1] > av[0])
        axis = (v[1] < 0) ? 3 : 2;
    else
        axis = (v[2] < 0) ? 5 : 4;

    /* Project texture coordinates */
    for (i = 0; i < nump; i++, vecs += 3) {
        j = vec_to_st[axis][2];
        dv = (j > 0) ? vecs[j - 1] : -vecs[-j - 1];
        if (dv < 0.001f) continue;

        j = vec_to_st[axis][0];
        s = (j < 0) ? -vecs[-j - 1] / dv : vecs[j - 1] / dv;
        j = vec_to_st[axis][1];
        t = (j < 0) ? -vecs[-j - 1] / dv : vecs[j - 1] / dv;

        if (s < skymins[0][axis]) skymins[0][axis] = s;
        if (t < skymins[1][axis]) skymins[1][axis] = t;
        if (s > skymaxs[0][axis]) skymaxs[0][axis] = s;
        if (t > skymaxs[1][axis]) skymaxs[1][axis] = t;
    }
}

#define ON_EPSILON 0.1f
#define MAX_CLIP_VERTS 64

static void ClipSkyPolygon(int nump, vec3_t vecs, int stage)
{
    float   *norm;
    float   *v;
    qboolean front, back;
    float   d, e;
    float   dists[MAX_CLIP_VERTS];
    int     sides[MAX_CLIP_VERTS];
    vec3_t  newv[2][MAX_CLIP_VERTS];
    int     newc[2];
    int     i, j;

    if (nump > MAX_CLIP_VERTS - 2) return;

    if (stage == 6) {
        DrawSkyPolygon(nump, vecs);
        return;
    }

    front = back = false;
    norm = skyclip[stage];
    for (i = 0, v = vecs; i < nump; i++, v += 3) {
        d = DotProduct(v, norm);
        if (d > ON_EPSILON) {
            front = true;
            sides[i] = SIDE_FRONT;
        } else if (d < -ON_EPSILON) {
            back = true;
            sides[i] = SIDE_BACK;
        } else {
            sides[i] = SIDE_ON;
        }
        dists[i] = d;
    }

    if (!front || !back) {
        ClipSkyPolygon(nump, vecs, stage + 1);
        return;
    }

    sides[i] = sides[0];
    dists[i] = dists[0];
    VectorCopy(vecs, (vecs + (i * 3)));
    newc[0] = newc[1] = 0;

    for (i = 0, v = vecs; i < nump; i++, v += 3) {
        switch (sides[i]) {
            case SIDE_FRONT:
                VectorCopy(v, newv[0][newc[0]]);
                newc[0]++;
                break;
            case SIDE_BACK:
                VectorCopy(v, newv[1][newc[1]]);
                newc[1]++;
                break;
            case SIDE_ON:
                VectorCopy(v, newv[0][newc[0]]);
                newc[0]++;
                VectorCopy(v, newv[1][newc[1]]);
                newc[1]++;
                break;
        }

        if (sides[i] == SIDE_ON || sides[i + 1] == SIDE_ON || sides[i + 1] == sides[i])
            continue;

        d = dists[i] / (dists[i] - dists[i + 1]);
        for (j = 0; j < 3; j++) {
            e = v[j] + d * (v[j + 3] - v[j]);
            newv[0][newc[0]][j] = e;
            newv[1][newc[1]][j] = e;
        }
        newc[0]++;
        newc[1]++;
    }

    ClipSkyPolygon(newc[0], newv[0][0], stage + 1);
    ClipSkyPolygon(newc[1], newv[1][0], stage + 1);
}

static void R_ClearSkyBox(void)
{
    for (int i = 0; i < 6; i++) {
        skymins[0][i] = skymins[1][i] = 9999;
        skymaxs[0][i] = skymaxs[1][i] = -9999;
    }
}

static void R_AddSkySurface(msurface_t *fa, vec3_t camera_origin)
{
    vec3_t verts[MAX_CLIP_VERTS];
    glpoly_t *p;

    for (p = fa->polys; p; p = p->next) {
        for (int i = 0; i < p->numverts; i++)
            VectorSubtract(p->verts[i], camera_origin, verts[i]);
        ClipSkyPolygon(p->numverts, verts[0], 0);
    }
}

static void MakeSkyVec(float s, float t, int axis, vec3_t v, float *out_s, float *out_t)
{
    vec3_t  b;
    int     j, k;

    b[0] = s * 2300;
    b[1] = t * 2300;
    b[2] = 2300;

    for (j = 0; j < 3; j++) {
        k = st_to_vec[axis][j];
        if (k < 0)
            v[j] = -b[-k - 1];
        else
            v[j] = b[k - 1];
    }

    /* Map s/t from [-1,1] to [0,1] range, clamped to avoid bilerp seams */
    s = (s + 1) * 0.5f;
    t = (t + 1) * 0.5f;
    if (s < sky_min) s = sky_min;
    else if (s > sky_max) s = sky_max;
    if (t < sky_min) t = sky_min;
    else if (t > sky_max) t = sky_max;
    t = 1.0f - t;

    *out_s = s;
    *out_t = t;
}

static void Metal_DrawSkyBox(id<MTLRenderCommandEncoder> encoder,
                              Q2FrameUniforms *uniforms,
                              vec3_t camera_origin)
{
    /* Process collected sky surfaces to determine visible faces */
    R_ClearSkyBox();
    for (int i = 0; i < num_sky_surfaces; i++)
        R_AddSkySurface(sky_surfaces[i], camera_origin);

    /* Set sky pipeline — depth test on but no depth write,
       so sky only shows through where no world geometry was drawn */
    [encoder setRenderPipelineState:mtl.skyPipeline];
    [encoder setDepthStencilState:mtl.depthReadOnly];
    [encoder setFragmentSamplerState:mtl.clampSampler atIndex:0];

    /* Build a model matrix that translates the skybox to camera origin,
       with optional rotation */
    simd_float4x4 skyModel = matrix_identity_float4x4;
    skyModel.columns[3] = (simd_float4){camera_origin[0], camera_origin[1],
                                         camera_origin[2], 1.0f};

    if (skyrotate) {
        /* Apply rotation around skyaxis */
        float angle = r_newrefdef.time * skyrotate * (M_PI / 180.0f);
        float c = cosf(angle), s = sinf(angle);
        float ax = skyaxis[0], ay = skyaxis[1], az = skyaxis[2];

        simd_float4x4 rot = {{
            {c + ax*ax*(1-c),      ay*ax*(1-c) + az*s,  az*ax*(1-c) - ay*s,  0},
            {ax*ay*(1-c) - az*s,   c + ay*ay*(1-c),     az*ay*(1-c) + ax*s,  0},
            {ax*az*(1-c) + ay*s,   ay*az*(1-c) - ax*s,  c + az*az*(1-c),     0},
            {0,                    0,                    0,                   1}
        }};

        skyModel = simd_mul(skyModel, rot);
    }

    Q2FrameUniforms skyUniforms = *uniforms;
    skyUniforms.modelMatrix = skyModel;
    [encoder setVertexBytes:&skyUniforms length:sizeof(Q2FrameUniforms)
                    atIndex:Q2BufferIndexFrameUniforms];
    [encoder setFragmentBytes:&skyUniforms length:sizeof(Q2FrameUniforms)
                      atIndex:Q2BufferIndexFrameUniforms];

    for (int i = 0; i < 6; i++) {
        if (skyrotate) {
            /* Force full sky faces when rotating */
            skymins[0][i] = -1;
            skymins[1][i] = -1;
            skymaxs[0][i] = 1;
            skymaxs[1][i] = 1;
        }

        if (skymins[0][i] >= skymaxs[0][i] ||
            skymins[1][i] >= skymaxs[1][i])
            continue;

        /* Bind sky face texture */
        image_t *skyimg = sky_images[skytexorder[i]];
        if (!skyimg || !skyimg->texture) continue;
        [encoder setFragmentTexture:skyimg->texture atIndex:Q2TextureIndexDiffuse];

        /* Build a quad from the sky face's visible s/t range */
        vec3_t v00, v01, v10, v11;
        float s00, t00, s01, t01, s10, t10, s11, t11;

        MakeSkyVec(skymins[0][i], skymins[1][i], i, v00, &s00, &t00);
        MakeSkyVec(skymins[0][i], skymaxs[1][i], i, v01, &s01, &t01);
        MakeSkyVec(skymaxs[0][i], skymaxs[1][i], i, v10, &s10, &t10);
        MakeSkyVec(skymaxs[0][i], skymins[1][i], i, v11, &s11, &t11);

        /* Two triangles for the quad */
        Q2WorldVertex quad[6];
        /* Triangle 1: v00, v01, v10 */
        quad[0] = (Q2WorldVertex){{v00[0], v00[1], v00[2]}, {s00, t00}, {0, 0}};
        quad[1] = (Q2WorldVertex){{v01[0], v01[1], v01[2]}, {s01, t01}, {0, 0}};
        quad[2] = (Q2WorldVertex){{v10[0], v10[1], v10[2]}, {s10, t10}, {0, 0}};
        /* Triangle 2: v00, v10, v11 */
        quad[3] = (Q2WorldVertex){{v00[0], v00[1], v00[2]}, {s00, t00}, {0, 0}};
        quad[4] = (Q2WorldVertex){{v10[0], v10[1], v10[2]}, {s10, t10}, {0, 0}};
        quad[5] = (Q2WorldVertex){{v11[0], v11[1], v11[2]}, {s11, t11}, {0, 0}};

        [encoder setVertexBytes:quad
                         length:sizeof(quad)
                        atIndex:Q2BufferIndexVertices];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:6];
    }

    /* Restore depth state */
    [encoder setDepthStencilState:mtl.depthEnabled];
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
        Metal_ClearSkySurfaces();
        Metal_SetupFrame(fd);
        Metal_DrawWorld(mtl.currentEncoder, &uniforms);
    }

    /* Draw sky behind world geometry */
    if (r_worldmodel && num_sky_surfaces > 0) {
        Metal_DrawSkyBox(mtl.currentEncoder, &uniforms, fd->vieworg);
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

        Metal_SetVertexData(mtl.currentEncoder, mtl.hudVertices,
                            mtl.hudVertexCount * sizeof(Q2HUDVertex), 0);
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
