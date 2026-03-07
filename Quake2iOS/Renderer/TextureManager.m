/*
 * TextureManager.m
 * Texture loading and caching for Metal renderer
 * Ports gl_image.c texture management
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "../../qcommon/qcommon.h"
#include "../../qcommon/qfiles.h"
#include "TextureManager.h"

/* Global state */
static id<MTLDevice> mtl_device;
unsigned d_8to24table[256];
image_t metal_textures[MAX_METAL_TEXTURES];
int num_metal_textures = 0;
int metal_registration_sequence = 0;

/* ================================================================ */
#pragma mark - Palette Loading
/* ================================================================ */

void Metal_LoadPalette(void)
{
    byte *pal, *raw;
    int len;

    len = FS_LoadFile("pics/colormap.pcx", (void **)&raw);
    if (!raw) {
        Com_Error(ERR_FATAL, "Couldn't load pics/colormap.pcx");
        return;
    }

    /* PCX palette is in the last 768 bytes */
    if (len < 768 + 1) {
        FS_FreeFile(raw);
        Com_Error(ERR_FATAL, "pics/colormap.pcx is too small");
        return;
    }

    pal = raw + len - 768;

    for (int i = 0; i < 256; i++) {
        unsigned r = pal[i * 3 + 0];
        unsigned g = pal[i * 3 + 1];
        unsigned b = pal[i * 3 + 2];
        unsigned a = (i == 255) ? 0 : 255; /* Index 255 is transparent */
        d_8to24table[i] = r | (g << 8) | (b << 16) | (a << 24);
    }

    FS_FreeFile(raw);
    Com_Printf("Metal_LoadPalette: loaded 256-color palette\n");
}

/* ================================================================ */
#pragma mark - PCX Loading
/* ================================================================ */

void LoadPCX_RGBA(char *filename, byte **pic, int *width, int *height)
{
    byte *raw;
    int len;

    *pic = NULL;
    if (width) *width = 0;
    if (height) *height = 0;

    len = FS_LoadFile(filename, (void **)&raw);
    if (!raw) return;

    pcx_t *pcx = (pcx_t *)raw;
    pcx->xmin = LittleShort(pcx->xmin);
    pcx->ymin = LittleShort(pcx->ymin);
    pcx->xmax = LittleShort(pcx->xmax);
    pcx->ymax = LittleShort(pcx->ymax);

    int w = pcx->xmax - pcx->xmin + 1;
    int h = pcx->ymax - pcx->ymin + 1;

    if (pcx->manufacturer != 0x0a || pcx->version != 5 ||
        pcx->encoding != 1 || pcx->bits_per_pixel != 8 ||
        w <= 0 || h <= 0 || w > 4096 || h > 4096) {
        Com_Printf("Bad PCX file %s\n", filename);
        FS_FreeFile(raw);
        return;
    }

    byte *out = malloc(w * h * 4);
    if (!out) {
        FS_FreeFile(raw);
        return;
    }

    if (width) *width = w;
    if (height) *height = h;
    *pic = out;

    /* Use palette from end of PCX if available, otherwise global palette */
    byte *palette;
    if (len > 768 + 1 && raw[len - 769] == 0x0C) {
        palette = raw + len - 768;
    } else {
        palette = (byte *)d_8to24table; /* Fallback: use as-is, it's RGBA */
    }

    /* RLE decode */
    byte *src = raw + sizeof(pcx_t);
    byte *end = raw + len;

    for (int y = 0; y < h; y++) {
        byte *row = out + y * w * 4;
        int x = 0;
        while (x < w && src < end) {
            byte dataByte = *src++;
            int runLength;
            byte paletteIndex;

            if ((dataByte & 0xC0) == 0xC0) {
                runLength = dataByte & 0x3F;
                if (src >= end) break;
                paletteIndex = *src++;
            } else {
                runLength = 1;
                paletteIndex = dataByte;
            }

            while (runLength > 0 && x < w) {
                unsigned color = d_8to24table[paletteIndex];
                row[x * 4 + 0] = color & 0xFF;
                row[x * 4 + 1] = (color >> 8) & 0xFF;
                row[x * 4 + 2] = (color >> 16) & 0xFF;
                row[x * 4 + 3] = (color >> 24) & 0xFF;
                x++;
                runLength--;
            }
        }
    }

    FS_FreeFile(raw);
}

/* ================================================================ */
#pragma mark - WAL Loading
/* ================================================================ */

void LoadWAL_RGBA(char *filename, byte **pic, int *width, int *height, imagetype_t type)
{
    byte *raw;
    int len;

    *pic = NULL;
    if (width) *width = 0;
    if (height) *height = 0;

    len = FS_LoadFile(filename, (void **)&raw);
    if (!raw) return;

    miptex_t *mt = (miptex_t *)raw;
    int w = LittleLong(mt->width);
    int h = LittleLong(mt->height);
    int ofs = LittleLong(mt->offsets[0]);

    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || ofs < 0) {
        Com_Printf("Bad WAL file %s\n", filename);
        FS_FreeFile(raw);
        return;
    }

    if (width) *width = w;
    if (height) *height = h;

    byte *out = malloc(w * h * 4);
    if (!out) {
        FS_FreeFile(raw);
        return;
    }

    *pic = out;
    byte *pixels = raw + ofs;

    for (int i = 0; i < w * h; i++) {
        unsigned color = d_8to24table[pixels[i]];
        out[i * 4 + 0] = color & 0xFF;
        out[i * 4 + 1] = (color >> 8) & 0xFF;
        out[i * 4 + 2] = (color >> 16) & 0xFF;
        out[i * 4 + 3] = (color >> 24) & 0xFF;
    }

    FS_FreeFile(raw);
}

/* ================================================================ */
#pragma mark - Metal Texture Creation
/* ================================================================ */

static id<MTLTexture> Metal_CreateTexture(byte *rgba, int width, int height, BOOL mipmap)
{
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:height mipmapped:mipmap];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [mtl_device newTextureWithDescriptor:desc];
    if (!tex) return nil;

    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:rgba
           bytesPerRow:width * 4];

    return tex;
}

/* ================================================================ */
#pragma mark - Image Cache
/* ================================================================ */

void Metal_InitImages(id<MTLDevice> device)
{
    mtl_device = device;
    memset(metal_textures, 0, sizeof(metal_textures));
    num_metal_textures = 0;
    Metal_LoadPalette();
}

void Metal_ShutdownImages(void)
{
    for (int i = 0; i < num_metal_textures; i++) {
        metal_textures[i].texture = nil;
        metal_textures[i].registration_sequence = 0;
    }
    num_metal_textures = 0;
    mtl_device = nil;
}

image_t *Metal_FindImage(char *name, imagetype_t type)
{
    if (!name || !name[0])
        return NULL;

    /* Normalize the name */
    char clean[64];
    int len = (int)strlen(name);
    if (len >= 64) len = 63;
    memcpy(clean, name, len);
    clean[len] = 0;

    /* Search existing textures */
    for (int i = 0; i < num_metal_textures; i++) {
        if (!strcmp(clean, metal_textures[i].name)) {
            metal_textures[i].registration_sequence = metal_registration_sequence;
            return &metal_textures[i];
        }
    }

    /* Not found - load it */
    byte *pic = NULL;
    int w = 0, h = 0;

    /* Determine format from extension or type */
    if (strstr(clean, ".pcx")) {
        LoadPCX_RGBA(clean, &pic, &w, &h);
    } else if (strstr(clean, ".wal")) {
        LoadWAL_RGBA(clean, &pic, &w, &h, type);
    } else if (strstr(clean, ".tga")) {
        LoadTGA_RGBA(clean, &pic, &w, &h);
    } else {
        /* Try with extensions */
        char tryname[72];

        snprintf(tryname, sizeof(tryname), "%s.pcx", clean);
        LoadPCX_RGBA(tryname, &pic, &w, &h);

        if (!pic) {
            snprintf(tryname, sizeof(tryname), "%s.wal", clean);
            LoadWAL_RGBA(tryname, &pic, &w, &h, type);
        }
        if (!pic) {
            snprintf(tryname, sizeof(tryname), "%s.tga", clean);
            LoadTGA_RGBA(tryname, &pic, &w, &h);
        }
    }

    if (!pic) {
        Com_Printf("Metal_FindImage: can't load %s\n", clean);
        return NULL;
    }

    /* Create Metal texture */
    BOOL mipmap = (type != it_pic && type != it_sky);
    id<MTLTexture> tex = Metal_CreateTexture(pic, w, h, mipmap);
    free(pic);

    if (!tex) {
        Com_Printf("Metal_FindImage: failed to create texture for %s\n", clean);
        return NULL;
    }

    /* Find a free slot */
    image_t *img = NULL;
    if (num_metal_textures < MAX_METAL_TEXTURES) {
        img = &metal_textures[num_metal_textures++];
    } else {
        /* Find first unused */
        for (int i = 0; i < MAX_METAL_TEXTURES; i++) {
            if (metal_textures[i].registration_sequence == 0) {
                img = &metal_textures[i];
                break;
            }
        }
    }

    if (!img) {
        Com_Printf("Metal_FindImage: out of texture slots for %s\n", clean);
        return NULL;
    }

    strncpy(img->name, clean, sizeof(img->name) - 1);
    img->type = type;
    img->width = w;
    img->height = h;
    img->registration_sequence = metal_registration_sequence;
    img->texture = tex;
    img->has_alpha = false;
    img->texturechain = NULL;

    return img;
}

void Metal_FreeUnusedImages(void)
{
    for (int i = 0; i < num_metal_textures; i++) {
        if (metal_textures[i].registration_sequence == metal_registration_sequence)
            continue;
        if (metal_textures[i].registration_sequence == 0)
            continue;
        /* Free this texture */
        metal_textures[i].texture = nil;
        metal_textures[i].name[0] = 0;
        metal_textures[i].registration_sequence = 0;
    }
}

/* ================================================================ */
#pragma mark - TGA Loading (stub)
/* ================================================================ */

void LoadTGA_RGBA(char *filename, byte **pic, int *width, int *height)
{
    byte *raw;
    int len;

    *pic = NULL;
    if (width) *width = 0;
    if (height) *height = 0;

    len = FS_LoadFile(filename, (void **)&raw);
    if (!raw) return;

    /* TGA header */
    byte idLength = raw[0];
    byte imageType = raw[2];
    int w = raw[12] | (raw[13] << 8);
    int h = raw[14] | (raw[15] << 8);
    int bpp = raw[16];
    byte descriptor = raw[17];

    if (imageType != 2 && imageType != 10) {
        /* Only support uncompressed and RLE true-color */
        FS_FreeFile(raw);
        return;
    }

    if (bpp != 24 && bpp != 32) {
        FS_FreeFile(raw);
        return;
    }

    if (width) *width = w;
    if (height) *height = h;

    byte *out = malloc(w * h * 4);
    if (!out) {
        FS_FreeFile(raw);
        return;
    }
    *pic = out;

    byte *src = raw + 18 + idLength;
    int pixelSize = bpp / 8;
    qboolean flipV = !(descriptor & 0x20); /* Bit 5: top-to-bottom */

    if (imageType == 2) {
        /* Uncompressed */
        for (int y = 0; y < h; y++) {
            int destY = flipV ? (h - 1 - y) : y;
            byte *row = out + destY * w * 4;
            for (int x = 0; x < w; x++) {
                row[x * 4 + 2] = src[0]; /* B */
                row[x * 4 + 1] = src[1]; /* G */
                row[x * 4 + 0] = src[2]; /* R */
                row[x * 4 + 3] = (bpp == 32) ? src[3] : 255;
                src += pixelSize;
            }
        }
    } else {
        /* RLE compressed */
        int pixel = 0;
        while (pixel < w * h) {
            byte header = *src++;
            int count = (header & 0x7F) + 1;
            if (header & 0x80) {
                /* RLE packet */
                byte b = src[0], g = src[1], r = src[2];
                byte a = (bpp == 32) ? src[3] : 255;
                src += pixelSize;
                for (int i = 0; i < count && pixel < w * h; i++, pixel++) {
                    int y = pixel / w;
                    int x = pixel % w;
                    int destY = flipV ? (h - 1 - y) : y;
                    byte *p = out + (destY * w + x) * 4;
                    p[0] = r; p[1] = g; p[2] = b; p[3] = a;
                }
            } else {
                /* Raw packet */
                for (int i = 0; i < count && pixel < w * h; i++, pixel++) {
                    int y = pixel / w;
                    int x = pixel % w;
                    int destY = flipV ? (h - 1 - y) : y;
                    byte *p = out + (destY * w + x) * 4;
                    p[2] = src[0]; p[1] = src[1]; p[0] = src[2];
                    p[3] = (bpp == 32) ? src[3] : 255;
                    src += pixelSize;
                }
            }
        }
    }

    FS_FreeFile(raw);
}
