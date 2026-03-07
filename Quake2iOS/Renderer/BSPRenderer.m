/*
 * BSPRenderer.m
 * BSP world surface rendering for Metal
 * Ports ref_gl/gl_rsurf.c and gl_rmain.c
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#include "../../qcommon/qcommon.h"
#include "../../client/ref.h"
#include "ModelTypes.h"
#include "TextureManager.h"
#include "RendererTypes.h"

/* ================================================================ */
#pragma mark - External State
/* ================================================================ */

extern id<MTLDevice> mtl_device_global;
extern id<MTLRenderCommandEncoder> mtl_encoder_global;
extern id<MTLRenderPipelineState> mtl_worldPipeline;
extern id<MTLRenderPipelineState> mtl_warpPipeline;
extern id<MTLSamplerState> mtl_samplerState;
extern id<MTLTexture> mtl_whiteTexture;
extern id<MTLTexture> lightmap_textures[];
extern int num_lightmap_textures;

extern refdef_t r_newrefdef;

/* ================================================================ */
#pragma mark - View State
/* ================================================================ */

static int r_visframecount = 0;
static int r_framecount = 0;
static vec3_t r_origin;
static vec3_t vpn, vright, vup;
static cplane_t frustum[4];
static int viewcluster, viewcluster2;
static int oldviewcluster, oldviewcluster2;

/* Alpha surfaces chain */
static msurface_t *r_alpha_surfaces = NULL;

/* Registration sequence */
static int r_registration_sequence = 0;

/* ================================================================ */
#pragma mark - Frustum
/* ================================================================ */

static void R_SetFrustum(void)
{
    /* Build frustum planes from view vectors and FOV */
    float fovx = r_newrefdef.fov_x;
    float fovy = r_newrefdef.fov_y;

    /* Right plane */
    float angle = DEG2RAD(90.0f - fovx * 0.5f);
    float s = sin(angle);
    float c = cos(angle);
    VectorScale(vpn, s, frustum[0].normal);
    VectorMA(frustum[0].normal, c, vright, frustum[0].normal);
    frustum[0].dist = DotProduct(r_origin, frustum[0].normal);
    frustum[0].type = PLANE_ANYZ;

    /* Left plane */
    VectorScale(vpn, s, frustum[1].normal);
    VectorMA(frustum[1].normal, -c, vright, frustum[1].normal);
    frustum[1].dist = DotProduct(r_origin, frustum[1].normal);
    frustum[1].type = PLANE_ANYZ;

    /* Bottom plane */
    angle = DEG2RAD(90.0f - fovy * 0.5f);
    s = sin(angle);
    c = cos(angle);
    VectorScale(vpn, s, frustum[2].normal);
    VectorMA(frustum[2].normal, c, vup, frustum[2].normal);
    frustum[2].dist = DotProduct(r_origin, frustum[2].normal);
    frustum[2].type = PLANE_ANYZ;

    /* Top plane */
    VectorScale(vpn, s, frustum[3].normal);
    VectorMA(frustum[3].normal, -c, vup, frustum[3].normal);
    frustum[3].dist = DotProduct(r_origin, frustum[3].normal);
    frustum[3].type = PLANE_ANYZ;

    for (int i = 0; i < 4; i++) {
        frustum[i].signbits = 0;
        for (int j = 0; j < 3; j++)
            if (frustum[i].normal[j] < 0)
                frustum[i].signbits |= 1 << j;
    }
}

static qboolean R_CullBox(vec3_t mins, vec3_t maxs)
{
    for (int i = 0; i < 4; i++) {
        cplane_t *p = &frustum[i];
        float dist;
        switch (p->signbits) {
            case 0: dist = p->normal[0]*maxs[0] + p->normal[1]*maxs[1] + p->normal[2]*maxs[2]; break;
            case 1: dist = p->normal[0]*mins[0] + p->normal[1]*maxs[1] + p->normal[2]*maxs[2]; break;
            case 2: dist = p->normal[0]*maxs[0] + p->normal[1]*mins[1] + p->normal[2]*maxs[2]; break;
            case 3: dist = p->normal[0]*mins[0] + p->normal[1]*mins[1] + p->normal[2]*maxs[2]; break;
            case 4: dist = p->normal[0]*maxs[0] + p->normal[1]*maxs[1] + p->normal[2]*mins[2]; break;
            case 5: dist = p->normal[0]*mins[0] + p->normal[1]*maxs[1] + p->normal[2]*mins[2]; break;
            case 6: dist = p->normal[0]*maxs[0] + p->normal[1]*mins[1] + p->normal[2]*mins[2]; break;
            case 7: dist = p->normal[0]*mins[0] + p->normal[1]*mins[1] + p->normal[2]*mins[2]; break;
            default: dist = 0; break;
        }
        if (dist < p->dist)
            return true;
    }
    return false;
}

/* ================================================================ */
#pragma mark - PVS Marking
/* ================================================================ */

static void R_MarkLeaves(void)
{
    if (oldviewcluster == viewcluster && oldviewcluster2 == viewcluster2)
        return;

    oldviewcluster = viewcluster;
    oldviewcluster2 = viewcluster2;
    r_visframecount++;

    if (!r_worldmodel->vis || viewcluster == -1) {
        /* Mark everything visible */
        for (int i = 0; i < r_worldmodel->numleafs; i++)
            r_worldmodel->leafs[i].visframe = r_visframecount;
        for (int i = 0; i < r_worldmodel->numnodes; i++)
            r_worldmodel->nodes[i].visframe = r_visframecount;
        return;
    }

    byte *vis = Mod_ClusterPVS(viewcluster, r_worldmodel);

    /* Also mark from the second cluster (for water boundaries) */
    byte fatvis[MAX_MAP_LEAFS / 8];
    if (viewcluster2 != viewcluster) {
        memcpy(fatvis, vis, (r_worldmodel->numleafs + 7) / 8);
        vis = Mod_ClusterPVS(viewcluster2, r_worldmodel);
        int bytes = (r_worldmodel->vis->numclusters + 7) >> 3;
        for (int i = 0; i < bytes; i++)
            fatvis[i] |= vis[i];
        vis = fatvis;
    }

    for (int i = 0; i < r_worldmodel->numleafs; i++) {
        mleaf_t *leaf = &r_worldmodel->leafs[i];
        int cluster = leaf->cluster;
        if (cluster == -1) continue;
        if (vis[cluster >> 3] & (1 << (cluster & 7))) {
            /* Mark this leaf and walk up to root */
            mnode_t *node = (mnode_t *)leaf;
            do {
                if (node->visframe == r_visframecount)
                    break;
                node->visframe = r_visframecount;
                node = node->parent;
            } while (node);
        }
    }
}

/* ================================================================ */
#pragma mark - Surface Rendering
/* ================================================================ */

static void Metal_DrawSurface(msurface_t *surf,
                              id<MTLRenderCommandEncoder> encoder,
                              Q2FrameUniforms *uniforms)
{
    glpoly_t *p = surf->polys;
    if (!p) return;

    image_t *tex = surf->texinfo->image;
    if (!tex || !tex->texture) return;

    /* Build vertex buffer from polygon */
    int numVerts = p->numverts;
    Q2WorldVertex verts[numVerts]; /* VLA */

    for (int i = 0; i < numVerts; i++) {
        verts[i].position.x = p->verts[i][0];
        verts[i].position.y = p->verts[i][1];
        verts[i].position.z = p->verts[i][2];
        verts[i].texcoord.x = p->verts[i][3];
        verts[i].texcoord.y = p->verts[i][4];
        verts[i].lightmapUV.x = p->verts[i][5];
        verts[i].lightmapUV.y = p->verts[i][6];
    }

    /* Set textures */
    [encoder setFragmentTexture:tex->texture atIndex:Q2TextureIndexDiffuse];

    if (surf->lightmaptexturenum >= 0 &&
        surf->lightmaptexturenum < num_lightmap_textures &&
        lightmap_textures[surf->lightmaptexturenum]) {
        [encoder setFragmentTexture:lightmap_textures[surf->lightmaptexturenum]
                            atIndex:Q2TextureIndexLightmap];
    }

    /* Draw as triangle fan */
    int numTris = numVerts - 2;
    if (numTris <= 0) return;

    Q2WorldVertex triVerts[numTris * 3];
    for (int i = 0; i < numTris; i++) {
        triVerts[i * 3 + 0] = verts[0];
        triVerts[i * 3 + 1] = verts[i + 1];
        triVerts[i * 3 + 2] = verts[i + 2];
    }

    /* setVertexBytes has a 4KB limit; use MTLBuffer for larger surfaces */
    NSUInteger vertLen = sizeof(Q2WorldVertex) * numTris * 3;
    if (vertLen <= 4096) {
        [encoder setVertexBytes:triVerts length:vertLen atIndex:Q2BufferIndexVertices];
    } else {
        id<MTLBuffer> buf = [mtl_device_global newBufferWithBytes:triVerts
                                                          length:vertLen
                                                         options:MTLResourceStorageModeShared];
        [encoder setVertexBuffer:buf offset:0 atIndex:Q2BufferIndexVertices];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:numTris * 3];
}

/* ================================================================ */
#pragma mark - BSP Traversal
/* ================================================================ */

static void R_RecursiveWorldNode(mnode_t *node,
                                  id<MTLRenderCommandEncoder> encoder,
                                  Q2FrameUniforms *uniforms)
{
    if (node->contents == CONTENTS_SOLID)
        return;

    if (node->visframe != r_visframecount)
        return;

    /* Frustum cull */
    if (R_CullBox(node->minmaxs, node->minmaxs + 3))
        return;

    /* Leaf */
    if (node->contents != -1) {
        mleaf_t *leaf = (mleaf_t *)node;

        /* Mark surfaces in this leaf */
        msurface_t **mark = leaf->firstmarksurface;
        int c = leaf->nummarksurfaces;
        if (c) {
            while (c--) {
                (*mark)->visframe = r_framecount;
                mark++;
            }
        }
        return;
    }

    /* Node — determine front/back */
    cplane_t *plane = node->plane;
    float dot;
    switch (plane->type) {
        case PLANE_X: dot = r_origin[0] - plane->dist; break;
        case PLANE_Y: dot = r_origin[1] - plane->dist; break;
        case PLANE_Z: dot = r_origin[2] - plane->dist; break;
        default: dot = DotProduct(r_origin, plane->normal) - plane->dist; break;
    }

    int side = (dot < 0) ? 1 : 0;

    /* Recurse front side */
    R_RecursiveWorldNode(node->children[side], encoder, uniforms);

    /* Draw surfaces on this node */
    msurface_t *surf = r_worldmodel->surfaces + node->firstsurface;
    for (int i = 0; i < node->numsurfaces; i++, surf++) {
        if (surf->visframe != r_framecount)
            continue;

        /* Backface cull */
        if (surf->flags & SURF_PLANEBACK) {
            float d = DotProduct(r_origin, surf->plane->normal) - surf->plane->dist;
            if (d > 0) continue;
        } else {
            float d = DotProduct(r_origin, surf->plane->normal) - surf->plane->dist;
            if (d < 0) continue;
        }

        /* Collect sky surfaces for skybox rendering */
        if (surf->flags & SURF_DRAWSKY) {
            extern void Metal_AddSkySurface(msurface_t *fa);
            Metal_AddSkySurface(surf);
            continue;
        }

        if (surf->texinfo->flags & (SURF_TRANS33 | SURF_TRANS66)) {
            /* Add to alpha chain */
            surf->texturechain = r_alpha_surfaces;
            r_alpha_surfaces = surf;
            continue;
        }

        if (surf->flags & SURF_DRAWTURB) {
            surf->texturechain = r_alpha_surfaces;
            r_alpha_surfaces = surf;
            continue;
        }

        /* Render opaque surface */
        Metal_DrawSurface(surf, encoder, uniforms);
    }

    /* Recurse back side */
    R_RecursiveWorldNode(node->children[!side], encoder, uniforms);
}

/* ================================================================ */
#pragma mark - Public API
/* ================================================================ */

void Metal_SetupFrame(refdef_t *fd)
{
    r_framecount++;

    VectorCopy(fd->vieworg, r_origin);

    /* Compute view vectors from angles */
    AngleVectors(fd->viewangles, vpn, vright, vup);

    /* Find view cluster */
    mleaf_t *leaf = Mod_PointInLeaf(r_origin, r_worldmodel);
    viewcluster = viewcluster2 = leaf->cluster;

    /* Check for water boundary */
    vec3_t temp;
    VectorCopy(r_origin, temp);
    if (!(leaf->contents & CONTENTS_SOLID)) {
        temp[2] -= 16;
        mleaf_t *leaf2 = Mod_PointInLeaf(temp, r_worldmodel);
        if (!(leaf2->contents & CONTENTS_SOLID) && leaf2->cluster != viewcluster)
            viewcluster2 = leaf2->cluster;
    } else {
        temp[2] += 16;
        mleaf_t *leaf2 = Mod_PointInLeaf(temp, r_worldmodel);
        if (!(leaf2->contents & CONTENTS_SOLID) && leaf2->cluster != viewcluster)
            viewcluster2 = leaf2->cluster;
    }

    R_SetFrustum();
    R_MarkLeaves();
}

void Metal_DrawWorld(id<MTLRenderCommandEncoder> encoder, Q2FrameUniforms *uniforms)
{
    if (!r_worldmodel) return;

    r_alpha_surfaces = NULL;

    /* Set world pipeline state */
    [encoder setRenderPipelineState:mtl_worldPipeline];
    [encoder setFragmentSamplerState:mtl_samplerState atIndex:0];

    /* Bind a white 1×1 texture as default lightmap so surfaces
       without lightmaps don't multiply by black (nil texture). */
    if (mtl_whiteTexture) {
        [encoder setFragmentTexture:mtl_whiteTexture atIndex:Q2TextureIndexLightmap];
    }

    /* Set uniforms */
    [encoder setVertexBytes:uniforms length:sizeof(Q2FrameUniforms)
                    atIndex:Q2BufferIndexFrameUniforms];
    [encoder setFragmentBytes:uniforms length:sizeof(Q2FrameUniforms)
                      atIndex:Q2BufferIndexFrameUniforms];

    /* Traverse BSP tree */
    R_RecursiveWorldNode(r_worldmodel->nodes, encoder, uniforms);
}

void Metal_DrawAlphaSurfaces(id<MTLRenderCommandEncoder> encoder, Q2FrameUniforms *uniforms)
{
    if (!r_alpha_surfaces) return;

    /* Set warp pipeline for translucent surfaces */
    [encoder setRenderPipelineState:mtl_warpPipeline];
    [encoder setFragmentSamplerState:mtl_samplerState atIndex:0];

    msurface_t *s = r_alpha_surfaces;
    while (s) {
        Metal_DrawSurface(s, encoder, uniforms);
        s = s->texturechain;
    }

    r_alpha_surfaces = NULL;
}

void Metal_ResetBSPState(void)
{
    r_visframecount = 0;
    r_framecount = 0;
    oldviewcluster = -1;
    oldviewcluster2 = -1;
    viewcluster = -1;
    viewcluster2 = -1;
    r_alpha_surfaces = NULL;
}
