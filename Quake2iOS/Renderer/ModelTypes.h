/*
 * ModelTypes.h
 * BSP and model data structures for the Metal renderer
 * Mirrors ref_gl/gl_model.h
 */

#ifndef ModelTypes_h
#define ModelTypes_h

#include "../../qcommon/qcommon.h"
#include "../../qcommon/qfiles.h"
#include "../../client/ref.h"
#include "TextureManager.h"
#include "RendererTypes.h"

#import <Metal/Metal.h>

/* Surface flags (from ref_gl/gl_model.h) — NOT the texinfo flags from q_shared.h */
#define SURF_PLANEBACK    2
#define SURF_DRAWSKY      4
#define SURF_DRAWTURB     0x10

#ifndef DEG2RAD
#define DEG2RAD(a) ((a) * M_PI / 180.0f)
#endif

/* ================================================================ */
/* BSP model structures                                              */
/* ================================================================ */

typedef struct mvertex_s {
    vec3_t      position;
} mvertex_t;

typedef struct medge_s {
    unsigned short v[2];
} medge_t;

typedef struct mtexinfo_s {
    float           vecs[2][4];
    int             flags;
    int             numframes;
    struct mtexinfo_s *next;    /* animation chain */
    image_t         *image;
} mtexinfo_t;

/* Pre-built polygon vertex data */
#define VERTEXSIZE 7 /* xyz s1t1 s2t2 */

typedef struct glpoly_s {
    struct glpoly_s *next;
    struct glpoly_s *chain;
    int             numverts;
    int             flags;
    float           verts[4][VERTEXSIZE]; /* variable sized */
} glpoly_t;

#define MAXLIGHTMAPS 4

typedef struct msurface_s {
    int             visframe;
    cplane_t        *plane;
    int             flags;

    int             firstedge;
    int             numedges;

    short           texturemins[2];
    short           extents[2];

    int             light_s, light_t;

    glpoly_t        *polys;
    struct msurface_s *texturechain;
    struct msurface_s *lightmapchain;

    mtexinfo_t      *texinfo;

    int             dlightframe;
    int             dlightbits;

    int             lightmaptexturenum;
    byte            styles[MAXLIGHTMAPS];
    float           cached_light[MAXLIGHTMAPS];
    byte            *samples;
} msurface_t;

typedef struct mnode_s {
    int             contents;   /* -1 = node, other = leaf */
    int             visframe;
    float           minmaxs[6];
    struct mnode_s  *parent;

    /* Node-specific */
    cplane_t        *plane;
    struct mnode_s  *children[2];
    unsigned short  firstsurface;
    unsigned short  numsurfaces;
} mnode_t;

typedef struct mleaf_s {
    int             contents;
    int             visframe;
    float           minmaxs[6];
    struct mnode_s  *parent;

    /* Leaf-specific */
    int             cluster;
    int             area;
    msurface_t      **firstmarksurface;
    int             nummarksurfaces;
} mleaf_t;

typedef struct mmodel_s {
    vec3_t          mins, maxs;
    vec3_t          origin;
    float           radius;
    int             headnode;
    int             visleafs;
    int             firstface, numfaces;
} mmodel_t;

/* ================================================================ */
/* Top-level model                                                    */
/* ================================================================ */

typedef enum { mod_bad, mod_brush, mod_sprite, mod_alias } modtype_t;

#define MAX_MD2SKINS 32

typedef struct model_s {
    char            name[64];   /* MAX_QPATH */
    int             registration_sequence;
    modtype_t       type;
    int             numframes;
    int             flags;

    vec3_t          mins, maxs;
    float           radius;

    /* Brush model data */
    int             firstmodelsurface, nummodelsurfaces;
    int             lightmap;

    int             numsubmodels;
    mmodel_t        *submodels;

    int             numplanes;
    cplane_t        *planes;

    int             numleafs;
    mleaf_t         *leafs;

    int             numvertexes;
    mvertex_t       *vertexes;

    int             numedges;
    medge_t         *edges;

    int             numnodes;
    int             firstnode;
    mnode_t         *nodes;

    int             numtexinfo;
    mtexinfo_t      *texinfo;

    int             numsurfaces;
    msurface_t      *surfaces;

    int             numsurfedges;
    int             *surfedges;

    int             nummarksurfaces;
    msurface_t      **marksurfaces;

    dvis_t          *vis;
    byte            *lightdata;

    /* Alias model skins */
    image_t         *skins[MAX_MD2SKINS];

    int             extradatasize;
    void            *extradata;
} model_t;

/* ================================================================ */
/* Model system API                                                   */
/* ================================================================ */

#define MAX_MOD_KNOWN 512

extern model_t mod_known[MAX_MOD_KNOWN];
extern int     mod_numknown;
extern model_t *r_worldmodel;

void        Mod_Init(void);
void        Mod_FreeAll(void);
model_t    *Mod_ForName(char *name, qboolean crash);
mleaf_t    *Mod_PointInLeaf(vec3_t p, model_t *model);
byte       *Mod_ClusterPVS(int cluster, model_t *model);

/* Lightmap atlas (ModelLoader.m) */
void        Metal_InitLightmaps(id<MTLDevice> device);

/* BSP renderer (BSPRenderer.m) */
void        Metal_SetupFrame(refdef_t *fd);
void        Metal_DrawWorld(id<MTLRenderCommandEncoder> encoder, Q2FrameUniforms *uniforms);
void        Metal_DrawAlphaSurfaces(id<MTLRenderCommandEncoder> encoder, Q2FrameUniforms *uniforms);
void        Metal_ResetBSPState(void);

/* Registration sequence (shared across renderer modules) */
extern int  metal_registration_sequence;

#endif /* ModelTypes_h */
