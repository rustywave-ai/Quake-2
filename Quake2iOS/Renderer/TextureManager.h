/*
 * TextureManager.h
 * Manages texture loading and caching for the Metal renderer
 * Ports texture loading from ref_gl/gl_image.c
 */

#ifndef TextureManager_h
#define TextureManager_h

#import <Metal/Metal.h>

/* Image types matching gl_local.h */
typedef enum {
    it_skin,
    it_sprite,
    it_wall,
    it_pic,
    it_sky
} imagetype_t;

/* Metal image structure (replaces gl_local.h image_t) */
typedef struct image_s {
    char            name[64];           /* MAX_QPATH */
    imagetype_t     type;
    int             width, height;
    int             registration_sequence;
    id<MTLTexture>  texture;
    qboolean        has_alpha;
    struct msurface_s *texturechain;    /* for sort-by-texture rendering */
} image_t;

#define MAX_METAL_TEXTURES 1024

/* Global palette (256 RGBA colors) loaded from colormap */
extern unsigned d_8to24table[256];

/* Texture cache */
extern image_t  metal_textures[MAX_METAL_TEXTURES];
extern int      num_metal_textures;

/* Core API */
void            Metal_InitImages(id<MTLDevice> device);
void            Metal_ShutdownImages(void);
image_t        *Metal_FindImage(char *name, imagetype_t type);
image_t        *Metal_LoadWAL(char *name);
image_t        *Metal_LoadPCX(char *name, imagetype_t type);
void            Metal_FreeUnusedImages(void);

/* Raw image loading (returns malloc'd RGBA buffer) */
void            LoadPCX_RGBA(char *filename, byte **pic, int *width, int *height);
void            LoadWAL_RGBA(char *filename, byte **pic, int *width, int *height, imagetype_t type);
void            LoadTGA_RGBA(char *filename, byte **pic, int *width, int *height);

/* Palette */
void            Metal_LoadPalette(void);

#endif /* TextureManager_h */
