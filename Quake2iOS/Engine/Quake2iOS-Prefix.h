/*
 * Quake2iOS-Prefix.h
 * Prefix header for compiling Quake 2 C engine code on iOS (ARM64)
 */

#ifndef Quake2iOS_Prefix_h
#define Quake2iOS_Prefix_h

/* Platform identification */
#define __IOS__ 1

/* Ensure Windows defines are not active */
#ifdef _WIN32
#undef _WIN32
#endif
#ifdef WIN32
#undef WIN32
#endif
#ifdef _M_IX86
#undef _M_IX86
#endif

/* iOS simulator paths can be 200+ chars; override Q2's 128-byte MAX_OSPATH */
#define MAX_OSPATH 512

/* Disable x86 assembly - we're ARM64 */
#undef id386
#define id386 0
#undef idaxp
#define idaxp 0

/* iOS uses POSIX/BSD */
#define HAVE_PTHREAD 1

/* Build string for version identification */
#define BUILDSTRING "iOS"
#define CPUSTRING "arm64"

/* stricmp is strcasecmp on POSIX */
#ifndef stricmp
#define stricmp strcasecmp
#endif

/*
 * Quake 2's q_shared.h defines: typedef enum {false, true} qboolean;
 * Modern C/ObjC compilers predefine true/false via stdbool.h.
 * Undefine them so the Quake enum compiles cleanly.
 */
#undef true
#undef false

/* iOS doesn't have strlwr */
#include <ctype.h>
static inline char *strlwr(char *s) {
    char *p = s;
    while (*p) { *p = tolower(*p); p++; }
    return s;
}

#endif /* Quake2iOS_Prefix_h */
