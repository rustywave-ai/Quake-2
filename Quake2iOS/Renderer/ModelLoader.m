/*
 * ModelLoader.m
 * BSP and alias model loading for Metal renderer
 * Ports ref_gl/gl_model.c
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "../../qcommon/qcommon.h"
#include "../../qcommon/qfiles.h"
#include "ModelTypes.h"
#include "TextureManager.h"

/* ================================================================ */
#pragma mark - Globals
/* ================================================================ */

model_t mod_known[MAX_MOD_KNOWN];
int mod_numknown = 0;
model_t *r_worldmodel = NULL;
model_t mod_inline[MAX_MOD_KNOWN];

static byte mod_novis[MAX_MAP_LEAFS / 8];
static byte *mod_base;

/* Memory pool for model data */
static byte *hunk_base;
static int hunk_size;
static int hunk_lowmark;

static void *Mod_Alloc(int size)
{
    size = (size + 31) & ~31; /* align to 32 bytes */
    if (hunk_lowmark + size > hunk_size) {
        Com_Error(ERR_DROP, "Mod_Alloc: overflow (need %d, have %d)",
                  hunk_lowmark + size, hunk_size);
        return NULL;
    }
    void *p = hunk_base + hunk_lowmark;
    hunk_lowmark += size;
    memset(p, 0, size);
    return p;
}

/* ================================================================ */
#pragma mark - PVS
/* ================================================================ */

mleaf_t *Mod_PointInLeaf(vec3_t p, model_t *model)
{
    if (!model || !model->nodes)
        Com_Error(ERR_DROP, "Mod_PointInLeaf: bad model");

    mnode_t *node = model->nodes;
    while (1) {
        if (node->contents != -1)
            return (mleaf_t *)node;
        cplane_t *plane = node->plane;
        float d = DotProduct(p, plane->normal) - plane->dist;
        node = (d > 0) ? node->children[0] : node->children[1];
    }
}

static void Mod_DecompressVis(byte *in, byte *out, int row)
{
    if (!in) {
        memset(out, 0xff, row);
        return;
    }

    byte *outEnd = out + row;
    while (out < outEnd) {
        if (*in) {
            *out++ = *in++;
            continue;
        }
        /* Run of zeros */
        in++;
        int c = *in++;
        if (out + c > outEnd)
            c = (int)(outEnd - out);
        memset(out, 0, c);
        out += c;
    }
}

byte *Mod_ClusterPVS(int cluster, model_t *model)
{
    static byte decompressed[MAX_MAP_LEAFS / 8];

    if (cluster == -1 || !model->vis) {
        memset(decompressed, 0xff, (model->numleafs + 7) / 8);
        return decompressed;
    }

    int row = (model->vis->numclusters + 7) >> 3;
    byte *visdata = (byte *)model->vis + model->vis->bitofs[cluster][DVIS_PVS];
    Mod_DecompressVis(visdata, decompressed, row);
    return decompressed;
}

/* ================================================================ */
#pragma mark - BSP Loading Subroutines
/* ================================================================ */

static void Mod_LoadVertexes(lump_t *l)
{
    dvertex_t *in = (dvertex_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dvertex_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    mvertex_t *out = Mod_Alloc(count * sizeof(mvertex_t));
    loadmodel->vertexes = out;
    loadmodel->numvertexes = count;

    for (int i = 0; i < count; i++) {
        out[i].position[0] = LittleFloat(in[i].point[0]);
        out[i].position[1] = LittleFloat(in[i].point[1]);
        out[i].position[2] = LittleFloat(in[i].point[2]);
    }
}

static void Mod_LoadEdges(lump_t *l)
{
    dedge_t *in = (dedge_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dedge_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    medge_t *out = Mod_Alloc((count + 1) * sizeof(medge_t));
    loadmodel->edges = out;
    loadmodel->numedges = count;

    for (int i = 0; i < count; i++) {
        out[i].v[0] = (unsigned short)LittleShort(in[i].v[0]);
        out[i].v[1] = (unsigned short)LittleShort(in[i].v[1]);
    }
}

static void Mod_LoadSurfedges(lump_t *l)
{
    int *in = (int *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(int);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    int *out = Mod_Alloc(count * sizeof(int));
    loadmodel->surfedges = out;
    loadmodel->numsurfedges = count;

    for (int i = 0; i < count; i++)
        out[i] = LittleLong(in[i]);
}

static void Mod_LoadLighting(lump_t *l)
{
    model_t *loadmodel = &mod_known[mod_numknown - 1];
    if (!l->filelen) {
        loadmodel->lightdata = NULL;
        return;
    }
    loadmodel->lightdata = Mod_Alloc(l->filelen);
    memcpy(loadmodel->lightdata, mod_base + l->fileofs, l->filelen);
}

static void Mod_LoadPlanes(lump_t *l)
{
    dplane_t *in = (dplane_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dplane_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    cplane_t *out = Mod_Alloc(count * 2 * sizeof(cplane_t));
    loadmodel->planes = out;
    loadmodel->numplanes = count;

    for (int i = 0; i < count; i++) {
        int bits = 0;
        for (int j = 0; j < 3; j++) {
            out[i].normal[j] = LittleFloat(in[i].normal[j]);
            if (out[i].normal[j] < 0) bits |= 1 << j;
        }
        out[i].dist = LittleFloat(in[i].dist);
        out[i].type = LittleLong(in[i].type);
        out[i].signbits = bits;
    }
}

static void Mod_LoadTexinfo(lump_t *l)
{
    texinfo_t *in = (texinfo_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(texinfo_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    mtexinfo_t *out = Mod_Alloc(count * sizeof(mtexinfo_t));
    loadmodel->texinfo = out;
    loadmodel->numtexinfo = count;

    for (int i = 0; i < count; i++) {
        for (int j = 0; j < 2; j++)
            for (int k = 0; k < 4; k++)
                out[i].vecs[j][k] = LittleFloat(in[i].vecs[j][k]);

        out[i].flags = LittleLong(in[i].flags);
        int next = LittleLong(in[i].nexttexinfo);
        out[i].next = (next > 0) ? &loadmodel->texinfo[next] : NULL;

        /* Load the texture */
        char texname[72];
        snprintf(texname, sizeof(texname), "textures/%s.wal", in[i].texture);
        out[i].image = Metal_FindImage(texname, it_wall);

        if (!out[i].image) {
            Com_Printf("Couldn't load %s\n", texname);
        }
    }
}

/* ================================================================ */
#pragma mark - Lightmap Atlas
/* ================================================================ */

#define BLOCK_WIDTH     128
#define BLOCK_HEIGHT    128
#define MAX_LIGHTMAPS   128
#define LIGHTMAP_BYTES  4

static int lightmap_allocated[BLOCK_WIDTH];
static int current_lightmap_texture;
static id<MTLDevice> lm_device;
id<MTLTexture> lightmap_textures[MAX_LIGHTMAPS];
int num_lightmap_textures = 0;

static byte lightmap_buffer[LIGHTMAP_BYTES * BLOCK_WIDTH * BLOCK_HEIGHT];

void Metal_InitLightmaps(id<MTLDevice> device)
{
    lm_device = device;
    memset(lightmap_allocated, 0, sizeof(lightmap_allocated));
    memset(lightmap_textures, 0, sizeof(lightmap_textures));
    current_lightmap_texture = 0;
    num_lightmap_textures = 0;
}

static qboolean LM_AllocBlock(int w, int h, int *x, int *y)
{
    int best = BLOCK_HEIGHT;

    for (int i = 0; i < BLOCK_WIDTH - w; i++) {
        int best2 = 0;
        int j;
        for (j = 0; j < w; j++) {
            if (lightmap_allocated[i + j] >= best)
                break;
            if (lightmap_allocated[i + j] > best2)
                best2 = lightmap_allocated[i + j];
        }
        if (j == w) {
            *x = i;
            *y = best = best2;
        }
    }

    if (best + h > BLOCK_HEIGHT)
        return false;

    for (int i = 0; i < w; i++)
        lightmap_allocated[*x + i] = best + h;

    return true;
}

static void LM_UploadBlock(void)
{
    if (current_lightmap_texture >= MAX_LIGHTMAPS)
        return;

    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:BLOCK_WIDTH height:BLOCK_HEIGHT mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [lm_device newTextureWithDescriptor:desc];
    [tex replaceRegion:MTLRegionMake2D(0, 0, BLOCK_WIDTH, BLOCK_HEIGHT)
           mipmapLevel:0
             withBytes:lightmap_buffer
           bytesPerRow:BLOCK_WIDTH * LIGHTMAP_BYTES];

    lightmap_textures[current_lightmap_texture] = tex;
    if (current_lightmap_texture >= num_lightmap_textures)
        num_lightmap_textures = current_lightmap_texture + 1;
}

static void Mod_BuildSurfaceLightmap(msurface_t *surf, model_t *loadmodel)
{
    if (surf->flags & (SURF_DRAWSKY | SURF_DRAWTURB))
        return;

    int smax = (surf->extents[0] >> 4) + 1;
    int tmax = (surf->extents[1] >> 4) + 1;

    if (!LM_AllocBlock(smax, tmax, &surf->light_s, &surf->light_t)) {
        LM_UploadBlock();
        current_lightmap_texture++;
        memset(lightmap_allocated, 0, sizeof(lightmap_allocated));

        if (!LM_AllocBlock(smax, tmax, &surf->light_s, &surf->light_t))
            Com_Error(ERR_DROP, "LM_AllocBlock: surface too large");
    }

    surf->lightmaptexturenum = current_lightmap_texture;

    /* Copy lightmap data into the atlas buffer */
    byte *src = surf->samples;
    if (!src) return;

    for (int t = 0; t < tmax; t++) {
        byte *dest = lightmap_buffer +
            ((surf->light_t + t) * BLOCK_WIDTH + surf->light_s) * LIGHTMAP_BYTES;
        for (int s = 0; s < smax; s++) {
            /* Lightmap data is RGB, replicated for each lightstyle */
            float r = 0, g = 0, b = 0;
            for (int maps = 0; maps < MAXLIGHTMAPS && surf->styles[maps] != 255; maps++) {
                r += src[0];
                g += src[1];
                b += src[2];
                src += 3;
            }

            /* Scale and clamp */
            r = fminf(r, 255.0f);
            g = fminf(g, 255.0f);
            b = fminf(b, 255.0f);

            dest[0] = (byte)r;
            dest[1] = (byte)g;
            dest[2] = (byte)b;
            dest[3] = 255;
            dest += LIGHTMAP_BYTES;
        }
    }
}

/* ================================================================ */
#pragma mark - Surface Building
/* ================================================================ */

static void CalcSurfaceExtents(msurface_t *s, model_t *loadmodel)
{
    float mins[2], maxs[2];
    mins[0] = mins[1] = 999999;
    maxs[0] = maxs[1] = -999999;

    mtexinfo_t *tex = s->texinfo;

    for (int i = 0; i < s->numedges; i++) {
        int e = loadmodel->surfedges[s->firstedge + i];
        mvertex_t *v;
        if (e >= 0)
            v = &loadmodel->vertexes[loadmodel->edges[e].v[0]];
        else
            v = &loadmodel->vertexes[loadmodel->edges[-e].v[1]];

        for (int j = 0; j < 2; j++) {
            float val = v->position[0] * tex->vecs[j][0] +
                        v->position[1] * tex->vecs[j][1] +
                        v->position[2] * tex->vecs[j][2] +
                        tex->vecs[j][3];
            if (val < mins[j]) mins[j] = val;
            if (val > maxs[j]) maxs[j] = val;
        }
    }

    for (int i = 0; i < 2; i++) {
        int bmins = (int)floor(mins[i] / 16.0f);
        int bmaxs = (int)ceil(maxs[i] / 16.0f);

        s->texturemins[i] = bmins * 16;
        s->extents[i] = (bmaxs - bmins) * 16;
    }
}

static void BuildPolygonFromSurface(msurface_t *fa, model_t *loadmodel)
{
    int numverts = fa->numedges;
    int allocSize = sizeof(glpoly_t) + (numverts - 4) * VERTEXSIZE * sizeof(float);
    glpoly_t *poly = Mod_Alloc(allocSize);

    poly->next = NULL;
    poly->numverts = numverts;
    fa->polys = poly;

    mtexinfo_t *texinfo = fa->texinfo;
    float texw = 64.0f, texh = 64.0f;
    if (texinfo->image) {
        texw = (float)texinfo->image->width;
        texh = (float)texinfo->image->height;
    }

    for (int i = 0; i < numverts; i++) {
        int idx = loadmodel->surfedges[fa->firstedge + i];
        mvertex_t *v;
        if (idx > 0)
            v = &loadmodel->vertexes[loadmodel->edges[idx].v[0]];
        else
            v = &loadmodel->vertexes[loadmodel->edges[-idx].v[1]];

        /* Position */
        poly->verts[i][0] = v->position[0];
        poly->verts[i][1] = v->position[1];
        poly->verts[i][2] = v->position[2];

        /* Diffuse texture coordinates */
        float s = DotProduct(v->position, texinfo->vecs[0]) + texinfo->vecs[0][3];
        float t = DotProduct(v->position, texinfo->vecs[1]) + texinfo->vecs[1][3];
        poly->verts[i][3] = s / texw;
        poly->verts[i][4] = t / texh;

        /* Lightmap texture coordinates */
        s -= fa->texturemins[0];
        s += fa->light_s * 16;
        s += 8;
        s /= BLOCK_WIDTH * 16;

        t -= fa->texturemins[1];
        t += fa->light_t * 16;
        t += 8;
        t /= BLOCK_HEIGHT * 16;

        poly->verts[i][5] = s;
        poly->verts[i][6] = t;
    }
}

/* ================================================================ */
#pragma mark - Face Loading
/* ================================================================ */

static void Mod_LoadFaces(lump_t *l)
{
    dface_t *in = (dface_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dface_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    msurface_t *out = Mod_Alloc(count * sizeof(msurface_t));
    loadmodel->surfaces = out;
    loadmodel->numsurfaces = count;

    for (int i = 0; i < count; i++) {
        out[i].firstedge = LittleLong(in[i].firstedge);
        out[i].numedges = LittleShort(in[i].numedges);
        out[i].flags = 0;

        int planenum = LittleShort(in[i].planenum);
        int side = LittleShort(in[i].side);
        if (side)
            out[i].flags |= SURF_PLANEBACK;

        out[i].plane = loadmodel->planes + planenum;

        int ti = LittleShort(in[i].texinfo);
        if (ti < 0 || ti >= loadmodel->numtexinfo)
            Com_Error(ERR_DROP, "Mod_LoadFaces: bad texinfo number");
        out[i].texinfo = loadmodel->texinfo + ti;

        /* Lightmap styles */
        for (int j = 0; j < MAXLIGHTMAPS; j++)
            out[i].styles[j] = in[i].styles[j];

        int lightofs = LittleLong(in[i].lightofs);
        if (lightofs == -1 || !loadmodel->lightdata)
            out[i].samples = NULL;
        else
            out[i].samples = loadmodel->lightdata + lightofs;

        /* Set surface flags from texinfo */
        if (out[i].texinfo->flags & SURF_WARP) {
            out[i].flags |= SURF_DRAWTURB;
        }
        if (out[i].texinfo->flags & SURF_SKY) {
            out[i].flags |= SURF_DRAWSKY;
        }

        CalcSurfaceExtents(&out[i], loadmodel);

        /* Build lightmap atlas entry */
        Mod_BuildSurfaceLightmap(&out[i], loadmodel);

        /* Build polygon geometry */
        BuildPolygonFromSurface(&out[i], loadmodel);
    }

    /* Upload the final lightmap page */
    LM_UploadBlock();
}

/* ================================================================ */
#pragma mark - Node/Leaf/Marksurface Loading
/* ================================================================ */

static void Mod_LoadMarksurfaces(lump_t *l)
{
    short *in = (short *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(short);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    msurface_t **out = Mod_Alloc(count * sizeof(msurface_t *));
    loadmodel->marksurfaces = out;
    loadmodel->nummarksurfaces = count;

    for (int i = 0; i < count; i++) {
        int j = LittleShort(in[i]);
        if (j < 0 || j >= loadmodel->numsurfaces)
            Com_Error(ERR_DROP, "Mod_LoadMarksurfaces: bad surface number");
        out[i] = loadmodel->surfaces + j;
    }
}

static void Mod_LoadVisibility(lump_t *l)
{
    model_t *loadmodel = &mod_known[mod_numknown - 1];
    if (!l->filelen) {
        loadmodel->vis = NULL;
        return;
    }
    loadmodel->vis = Mod_Alloc(l->filelen);
    memcpy(loadmodel->vis, mod_base + l->fileofs, l->filelen);

    /* Byte-swap */
    loadmodel->vis->numclusters = LittleLong(loadmodel->vis->numclusters);
    for (int i = 0; i < loadmodel->vis->numclusters; i++) {
        loadmodel->vis->bitofs[i][0] = LittleLong(loadmodel->vis->bitofs[i][0]);
        loadmodel->vis->bitofs[i][1] = LittleLong(loadmodel->vis->bitofs[i][1]);
    }
}

static void Mod_LoadLeafs(lump_t *l)
{
    dleaf_t *in = (dleaf_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dleaf_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    mleaf_t *out = Mod_Alloc(count * sizeof(mleaf_t));
    loadmodel->leafs = out;
    loadmodel->numleafs = count;

    for (int i = 0; i < count; i++) {
        out[i].contents = LittleLong(in[i].contents);
        out[i].cluster = LittleShort(in[i].cluster);
        out[i].area = LittleShort(in[i].area);

        int firstleafface = LittleShort(in[i].firstleafface);
        out[i].nummarksurfaces = LittleShort(in[i].numleaffaces);
        out[i].firstmarksurface = loadmodel->marksurfaces + firstleafface;

        for (int j = 0; j < 6; j++)
            out[i].minmaxs[j] = (float)LittleShort(in[i].mins[j < 3 ? j : j - 3]);
        /* Fix: mins are indices 0-2, maxs are 3-5 */
        for (int j = 0; j < 3; j++) {
            out[i].minmaxs[j] = (float)LittleShort(in[i].mins[j]);
            out[i].minmaxs[3 + j] = (float)LittleShort(in[i].maxs[j]);
        }
    }
}

static void Mod_LoadNodes(lump_t *l)
{
    dnode_t *in = (dnode_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dnode_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    mnode_t *out = Mod_Alloc(count * sizeof(mnode_t));
    loadmodel->nodes = out;
    loadmodel->numnodes = count;

    for (int i = 0; i < count; i++) {
        out[i].contents = -1; /* Nodes always have -1 */

        for (int j = 0; j < 3; j++) {
            out[i].minmaxs[j] = (float)LittleShort(in[i].mins[j]);
            out[i].minmaxs[3 + j] = (float)LittleShort(in[i].maxs[j]);
        }

        int planenum = LittleLong(in[i].planenum);
        out[i].plane = loadmodel->planes + planenum;

        out[i].firstsurface = LittleShort(in[i].firstface);
        out[i].numsurfaces = LittleShort(in[i].numfaces);

        for (int j = 0; j < 2; j++) {
            int child = LittleLong(in[i].children[j]);
            if (child >= 0)
                out[i].children[j] = loadmodel->nodes + child;
            else
                out[i].children[j] = (mnode_t *)(loadmodel->leafs + (-1 - child));
        }
    }

    /* Set parent pointers */
    for (int i = 0; i < count; i++) {
        for (int j = 0; j < 2; j++) {
            mnode_t *child = out[i].children[j];
            child->parent = &out[i];
        }
    }
}

static void Mod_LoadSubmodels(lump_t *l)
{
    dmodel_t *in = (dmodel_t *)(mod_base + l->fileofs);
    int count = l->filelen / sizeof(dmodel_t);
    model_t *loadmodel = &mod_known[mod_numknown - 1];

    mmodel_t *out = Mod_Alloc(count * sizeof(mmodel_t));
    loadmodel->submodels = out;
    loadmodel->numsubmodels = count;

    for (int i = 0; i < count; i++) {
        for (int j = 0; j < 3; j++) {
            out[i].mins[j] = LittleFloat(in[i].mins[j]) - 1;
            out[i].maxs[j] = LittleFloat(in[i].maxs[j]) + 1;
            out[i].origin[j] = LittleFloat(in[i].origin[j]);
        }
        out[i].radius = 0; /* Computed later if needed */
        out[i].headnode = LittleLong(in[i].headnode);
        out[i].firstface = LittleLong(in[i].firstface);
        out[i].numfaces = LittleLong(in[i].numfaces);
    }
}

/* ================================================================ */
#pragma mark - Brush Model Loading
/* ================================================================ */

static void Mod_LoadBrushModel(model_t *mod, void *buffer)
{
    dheader_t *header = (dheader_t *)buffer;

    if (LittleLong(header->version) != BSPVERSION) {
        Com_Error(ERR_DROP, "Mod_LoadBrushModel: %s has wrong version (%d should be %d)",
                  mod->name, LittleLong(header->version), BSPVERSION);
        return;
    }

    mod_base = (byte *)header;

    /* Byte-swap all lumps */
    for (int i = 0; i < sizeof(dheader_t) / 4; i++)
        ((int *)header)[i] = LittleLong(((int *)header)[i]);

    /* Load in order matching gl_model.c */
    Mod_LoadVertexes(&header->lumps[LUMP_VERTEXES]);
    Mod_LoadEdges(&header->lumps[LUMP_EDGES]);
    Mod_LoadSurfedges(&header->lumps[LUMP_SURFEDGES]);
    Mod_LoadLighting(&header->lumps[LUMP_LIGHTING]);
    Mod_LoadPlanes(&header->lumps[LUMP_PLANES]);
    Mod_LoadTexinfo(&header->lumps[LUMP_TEXINFO]);
    Mod_LoadFaces(&header->lumps[LUMP_FACES]);
    Mod_LoadMarksurfaces(&header->lumps[LUMP_LEAFFACES]);
    Mod_LoadVisibility(&header->lumps[LUMP_VISIBILITY]);
    Mod_LoadLeafs(&header->lumps[LUMP_LEAFS]);
    Mod_LoadNodes(&header->lumps[LUMP_NODES]);
    Mod_LoadSubmodels(&header->lumps[LUMP_MODELS]);

    mod->numframes = 2; /* Regular + alternate animation */
    mod->type = mod_brush;

    /* Set up submodels (inline BSP models like doors, platforms) */
    for (int i = 0; i < mod->numsubmodels; i++) {
        model_t *starmod = &mod_inline[i];
        *starmod = *mod;

        starmod->firstmodelsurface = mod->submodels[i].firstface;
        starmod->nummodelsurfaces = mod->submodels[i].numfaces;
        starmod->firstnode = mod->submodels[i].headnode;

        if (starmod->firstnode >= mod->numnodes)
            Com_Error(ERR_DROP, "Inline model %i has bad firstnode", i);

        VectorCopy(mod->submodels[i].maxs, starmod->maxs);
        VectorCopy(mod->submodels[i].mins, starmod->mins);
        starmod->radius = mod->submodels[i].radius;

        if (i == 0)
            *mod = *starmod;
    }
}

/* ================================================================ */
#pragma mark - Alias Model Loading
/* ================================================================ */

static void Mod_LoadAliasModel(model_t *mod, void *buffer)
{
    dmdl_t *pinmodel = (dmdl_t *)buffer;

    if (LittleLong(pinmodel->version) != ALIAS_VERSION) {
        Com_Error(ERR_DROP, "%s has wrong version (%d should be %d)",
                  mod->name, LittleLong(pinmodel->version), ALIAS_VERSION);
        return;
    }

    int size = LittleLong(pinmodel->ofs_end);
    dmdl_t *pheader = Mod_Alloc(size);
    memcpy(pheader, buffer, size);

    /* Byte-swap header fields */
    pheader->skinwidth = LittleLong(pheader->skinwidth);
    pheader->skinheight = LittleLong(pheader->skinheight);
    pheader->framesize = LittleLong(pheader->framesize);
    pheader->num_skins = LittleLong(pheader->num_skins);
    pheader->num_xyz = LittleLong(pheader->num_xyz);
    pheader->num_st = LittleLong(pheader->num_st);
    pheader->num_tris = LittleLong(pheader->num_tris);
    pheader->num_glcmds = LittleLong(pheader->num_glcmds);
    pheader->num_frames = LittleLong(pheader->num_frames);
    pheader->ofs_skins = LittleLong(pheader->ofs_skins);
    pheader->ofs_st = LittleLong(pheader->ofs_st);
    pheader->ofs_tris = LittleLong(pheader->ofs_tris);
    pheader->ofs_frames = LittleLong(pheader->ofs_frames);
    pheader->ofs_glcmds = LittleLong(pheader->ofs_glcmds);
    pheader->ofs_end = LittleLong(pheader->ofs_end);

    mod->type = mod_alias;
    mod->numframes = pheader->num_frames;
    mod->extradata = pheader;
    mod->extradatasize = size;

    /* Load skins */
    char *skinNames = (char *)pheader + pheader->ofs_skins;
    for (int i = 0; i < pheader->num_skins; i++) {
        char *skinname = skinNames + i * MAX_QPATH;
        mod->skins[i] = Metal_FindImage(skinname, it_skin);
    }

    /* Compute bounds */
    daliasframe_t *frame = (daliasframe_t *)((byte *)pheader + pheader->ofs_frames);
    VectorCopy(frame->translate, mod->mins);
    VectorMA(mod->mins, 255.0f, frame->scale, mod->maxs);
}

/* ================================================================ */
#pragma mark - Sprite Model Loading
/* ================================================================ */

static void Mod_LoadSpriteModel(model_t *mod, void *buffer)
{
    dsprite_t *sprin = (dsprite_t *)buffer;

    int size = sizeof(dsprite_t) + (LittleLong(sprin->numframes) - 1) * sizeof(dsprframe_t);
    dsprite_t *sprout = Mod_Alloc(size);
    memcpy(sprout, buffer, size);

    sprout->numframes = LittleLong(sprout->numframes);
    mod->type = mod_sprite;
    mod->numframes = sprout->numframes;
    mod->extradata = sprout;
    mod->extradatasize = size;

    for (int i = 0; i < sprout->numframes; i++) {
        mod->skins[i] = Metal_FindImage(sprout->frames[i].name, it_sprite);
    }
}

/* ================================================================ */
#pragma mark - Model System
/* ================================================================ */

void Mod_Init(void)
{
    memset(mod_known, 0, sizeof(mod_known));
    memset(mod_inline, 0, sizeof(mod_inline));
    memset(mod_novis, 0xff, sizeof(mod_novis));
    mod_numknown = 0;
}

model_t *Mod_ForName(char *name, qboolean crash)
{
    if (!name[0])
        Com_Error(ERR_DROP, "Mod_ForName: NULL name");

    /* Inline models */
    if (name[0] == '*') {
        int i = atoi(name + 1);
        if (i < 1 || !r_worldmodel || i >= r_worldmodel->numsubmodels)
            Com_Error(ERR_DROP, "bad inline model number");
        return &mod_inline[i];
    }

    /* Search existing */
    model_t *mod = NULL;
    int i;
    for (i = 0; i < mod_numknown; i++) {
        if (!strcmp(mod_known[i].name, name))
            return &mod_known[i];
        if (!mod_known[i].name[0])
            break; /* Free slot */
    }

    if (i == mod_numknown) {
        if (mod_numknown >= MAX_MOD_KNOWN) {
            Com_Error(ERR_DROP, "mod_numknown == MAX_MOD_KNOWN");
            return NULL;
        }
        mod_numknown++;
    }

    mod = &mod_known[i];
    memset(mod, 0, sizeof(*mod));
    strncpy(mod->name, name, sizeof(mod->name) - 1);

    /* Load the file */
    void *buf;
    int fileLen = FS_LoadFile(mod->name, &buf);
    if (!buf) {
        if (crash)
            Com_Error(ERR_DROP, "Mod_ForName: %s not found", mod->name);
        memset(mod->name, 0, sizeof(mod->name));
        return NULL;
    }

    /* Allocate memory pool for this model */
    hunk_size = fileLen * 8; /* Generous allocation */
    hunk_base = malloc(hunk_size);
    hunk_lowmark = 0;

    int ident = LittleLong(*(unsigned *)buf);

    switch (ident) {
        case IDBSPHEADER:
            Mod_LoadBrushModel(mod, buf);
            break;
        case IDALIASHEADER:
            Mod_LoadAliasModel(mod, buf);
            break;
        case IDSPRITEHEADER:
            Mod_LoadSpriteModel(mod, buf);
            break;
        default:
            Com_Error(ERR_DROP, "Mod_ForName: unknown fileid for %s", mod->name);
            break;
    }

    mod->extradatasize = hunk_lowmark;
    /* Note: hunk_base is intentionally not freed — model data lives there */

    FS_FreeFile(buf);
    return mod;
}

void Mod_FreeAll(void)
{
    for (int i = 0; i < mod_numknown; i++) {
        /* In a real implementation, we'd free the hunk allocations */
        memset(&mod_known[i], 0, sizeof(model_t));
    }
    mod_numknown = 0;
    r_worldmodel = NULL;
}
