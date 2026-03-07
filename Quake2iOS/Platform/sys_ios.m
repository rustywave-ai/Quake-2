/*
 * sys_ios.m
 * iOS platform layer for Quake 2
 * Replaces win32/sys_win.c
 */

#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <dirent.h>
#import <dlfcn.h>

#include "../../qcommon/qcommon.h"
#include "../../game/game.h"

/* Globals */
unsigned sys_frame_time;
int curtime;

/* Path storage - set by Swift before engine init */
static char ios_basepath[MAX_OSPATH];
static char ios_savepath[MAX_OSPATH];

/* Timing */
static uint64_t sys_timebase;
static mach_timebase_info_data_t sys_timebase_info;

/* Forward declare the game API function */
extern game_export_t *GetGameAPI(game_import_t *import);

/* ================================================================ */
#pragma mark - Initialization from Swift
/* ================================================================ */

void Quake2_Init(const char *basePath, const char *savePath)
{
    strncpy(ios_basepath, basePath, sizeof(ios_basepath) - 1);
    strncpy(ios_savepath, savePath, sizeof(ios_savepath) - 1);

    /* Set up timing */
    mach_timebase_info(&sys_timebase_info);
    sys_timebase = mach_absolute_time();

    /* Debug: verify PAK file access before engine init */
    char pakcheck[MAX_OSPATH];
    snprintf(pakcheck, sizeof(pakcheck), "%s/baseq2/pak0.pak", basePath);
    FILE *testpak = fopen(pakcheck, "rb");
    if (testpak) {
        NSLog(@"Quake2_Init: pak0.pak FOUND at %s", pakcheck);
        fclose(testpak);
    } else {
        NSLog(@"Quake2_Init: pak0.pak NOT FOUND at %s (errno=%d)", pakcheck, errno);
    }
    NSLog(@"Quake2_Init: basePath='%s' savePath='%s'", basePath, savePath);

    /* Initialize the engine — pass basedir so FS_InitFilesystem finds PAK files */
    char *argv[] = {
        "quake2",
        "+set", "basedir", (char *)basePath,
        NULL
    };
    int argc = 4;

    Qcommon_Init(argc, argv);

    Com_Printf("Quake2 iOS initialized\n");
}

void Quake2_Frame(int msec)
{
    Qcommon_Frame(msec);
}

void Quake2_Pause(void)
{
    Cbuf_AddText("pause\n");
}

void Quake2_Resume(void)
{
    /* Unpause if paused — the pause command toggles */
    if (Cvar_VariableValue("paused"))
        Cbuf_AddText("pause\n");
}

void Quake2_SetCvar(const char *name, const char *value)
{
    Cvar_Set((char *)name, (char *)value);
}

void Quake2_MemoryWarning(void)
{
    /* Free unused zone memory tagged for level data (TAG_LEVEL=766 from g_local.h) */
    Z_FreeTags(766);
    Com_Printf("Memory warning: freed level allocations\n");
}

void Quake2_Shutdown(void)
{
    Com_Quit();
}

const char *IOS_GetBasePath(void)
{
    return ios_basepath;
}

const char *IOS_GetSavePath(void)
{
    return ios_savepath;
}

/* ================================================================ */
#pragma mark - System IO (Sys_* functions)
/* ================================================================ */

void Sys_Error(char *error, ...)
{
    va_list argptr;
    char text[1024];

    CL_Shutdown();
    Qcommon_Shutdown();

    va_start(argptr, error);
    vsnprintf(text, sizeof(text), error, argptr);
    va_end(argptr);

    NSLog(@"Sys_Error: %s", text);

    /* On iOS we can't show a MessageBox, so just abort */
    abort();
}

void Sys_Quit(void)
{
    CL_Shutdown();
    Qcommon_Shutdown();
    exit(0);
}

void Sys_Init(void)
{
    /* Nothing platform-specific needed for iOS init */
}

int Sys_Milliseconds(void)
{
    uint64_t now = mach_absolute_time();
    uint64_t elapsed = now - sys_timebase;

    /* Convert to milliseconds */
    uint64_t millis = elapsed * sys_timebase_info.numer / sys_timebase_info.denom / 1000000;

    curtime = (int)millis;
    return curtime;
}

void Sys_Mkdir(char *path)
{
    mkdir(path, 0755);
}

void Sys_SendKeyEvents(void)
{
    /* On iOS, key events come through UIKit/touch handlers.
     * This is called from the game loop but we don't need to pump
     * a message queue like on Windows. */
    sys_frame_time = Sys_Milliseconds();
}

char *Sys_ConsoleInput(void)
{
    /* No console input on iOS */
    return NULL;
}

void Sys_ConsoleOutput(char *string)
{
    /* Route console output to NSLog */
    NSLog(@"%s", string);
}

void Sys_AppActivate(void)
{
    /* Handled by UIKit lifecycle */
}

void Sys_CopyProtect(void)
{
    /* No copy protection on iOS */
}

char *Sys_GetClipboardData(void)
{
    /* Could implement via UIPasteboard, but not needed for gameplay */
    return NULL;
}

/* ================================================================ */
#pragma mark - Game DLL (static linking on iOS)
/* ================================================================ */

void Sys_UnloadGame(void)
{
    /* Game is statically linked on iOS - nothing to unload */
}

void *Sys_GetGameAPI(void *parms)
{
    /* On iOS, the game is compiled as a static library.
     * We call GetGameApi directly instead of dlopen/dlsym. */
    return GetGameAPI((game_import_t *)parms);
}

/* ================================================================ */
#pragma mark - File finding (Sys_FindFirst/Next/Close)
/* ================================================================ */

static char findbase[MAX_OSPATH];
static char findpath[MAX_OSPATH];
static char findpattern[MAX_OSPATH];
static DIR *fdir = NULL;

static qboolean CompareAttributes(char *path, unsigned musthave, unsigned canthave)
{
    struct stat st;

    if (stat(path, &st) == -1)
        return false;

    if ((canthave & SFF_SUBDIR) && S_ISDIR(st.st_mode))
        return false;

    if ((musthave & SFF_SUBDIR) && !S_ISDIR(st.st_mode))
        return false;

    return true;
}

/* Simple glob matching */
static qboolean GlobMatch(const char *pattern, const char *name)
{
    while (*pattern) {
        if (*pattern == '*') {
            pattern++;
            if (!*pattern) return true;
            while (*name) {
                if (GlobMatch(pattern, name)) return true;
                name++;
            }
            return false;
        } else if (*pattern == '?') {
            if (!*name) return false;
            pattern++;
            name++;
        } else {
            if (tolower(*pattern) != tolower(*name)) return false;
            pattern++;
            name++;
        }
    }
    return *name == 0;
}

char *Sys_FindFirst(char *path, unsigned musthave, unsigned canthave)
{
    struct dirent *d;
    char *p;

    if (fdir)
        Sys_Error("Sys_FindFirst without close");

    strncpy(findbase, path, sizeof(findbase) - 1);

    if ((p = strrchr(findbase, '/')) != NULL) {
        *p = 0;
        strncpy(findpattern, p + 1, sizeof(findpattern) - 1);
    } else {
        strcpy(findbase, ".");
        strncpy(findpattern, path, sizeof(findpattern) - 1);
    }

    fdir = opendir(findbase);
    if (!fdir)
        return NULL;

    while ((d = readdir(fdir)) != NULL) {
        if (!GlobMatch(findpattern, d->d_name))
            continue;
        snprintf(findpath, sizeof(findpath), "%s/%s", findbase, d->d_name);
        if (CompareAttributes(findpath, musthave, canthave))
            return findpath;
    }

    return NULL;
}

char *Sys_FindNext(unsigned musthave, unsigned canthave)
{
    struct dirent *d;

    if (!fdir)
        return NULL;

    while ((d = readdir(fdir)) != NULL) {
        if (!GlobMatch(findpattern, d->d_name))
            continue;
        snprintf(findpath, sizeof(findpath), "%s/%s", findbase, d->d_name);
        if (CompareAttributes(findpath, musthave, canthave))
            return findpath;
    }

    return NULL;
}

void Sys_FindClose(void)
{
    if (fdir) {
        closedir(fdir);
        fdir = NULL;
    }
}

/* ================================================================ */
#pragma mark - Hunk memory allocation
/* ================================================================ */

static byte *membase;
static int maxhunksize;
static int curhunksize;

void *Hunk_Begin(int maxsize)
{
    maxhunksize = maxsize;
    curhunksize = 0;
    membase = malloc(maxhunksize);
    if (!membase)
        Sys_Error("Hunk_Begin: failed on %i bytes", maxsize);
    memset(membase, 0, maxsize);
    return membase;
}

void *Hunk_Alloc(int size)
{
    byte *buf;

    /* round to cacheline */
    size = (size + 31) & ~31;

    if (curhunksize + size > maxhunksize)
        Sys_Error("Hunk_Alloc overflow");

    buf = membase + curhunksize;
    curhunksize += size;

    return buf;
}

int Hunk_End(void)
{
    /* We could realloc to shrink, but it's fine to keep the full allocation */
    return curhunksize;
}

void Hunk_Free(void *buf)
{
    if (membase) {
        free(membase);
        membase = NULL;
    }
}
