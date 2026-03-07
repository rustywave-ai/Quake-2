/*
 * vid_ios.m
 * iOS video system for Quake 2
 * Manages the Metal view and renderer DLL interface
 * Replaces win32/vid_dll.c
 */

#import <Foundation/Foundation.h>

#include "../../qcommon/qcommon.h"
#include "../../client/vid.h"
#include "../../client/ref.h"

/* Forward declare the Metal renderer entry point */
extern refexport_t Metal_GetRefAPI(refimport_t rimp);

/* The renderer functions - filled in by Metal_GetRefAPI */
refexport_t re;

/* Screen dimensions - updated from Swift */
static int vid_width = 1280;
static int vid_height = 720;

/* Cvars */
cvar_t *vid_ref;
cvar_t *vid_fullscreen;
cvar_t *vid_gamma;

/* Global for client code that needs the window handle */
void *cl_hwnd = NULL;

/* Video definition — referenced by client code */
viddef_t viddef;

/* ================================================================ */
#pragma mark - refimport_t callbacks (renderer → engine)
/* ================================================================ */

/*
 * Wrapper functions to match refimport_t signatures.
 * refimport_t.Sys_Error expects (int err_level, char *str, ...)
 * but the engine's Sys_Error is (char *error, ...).
 * Same issue with Con_Printf vs Com_Printf.
 */

#include <stdarg.h>

static void VID_Sys_Error(int err_level, char *str, ...)
{
    va_list argptr;
    char msg[1024];

    va_start(argptr, str);
    vsnprintf(msg, sizeof(msg), str, argptr);
    va_end(argptr);

    Com_Error(err_level, "%s", msg);
}

static void VID_Con_Printf(int print_level, char *str, ...)
{
    va_list argptr;
    char msg[4096];

    va_start(argptr, str);
    vsnprintf(msg, sizeof(msg), str, argptr);
    va_end(argptr);

    Com_Printf("%s", msg);
}

static qboolean VID_GetModeInfo(int *width, int *height, int mode)
{
    /* On iOS we just use the device's screen size */
    *width = vid_width;
    *height = vid_height;
    return true;
}

void VID_MenuInit(void)
{
    /* No video mode menu on iOS */
}

static void VID_NewWindow(int width, int height)
{
    vid_width = width;
    vid_height = height;
}

/* ================================================================ */
#pragma mark - VID interface
/* ================================================================ */

/*
 * VID_Init
 * Called from CL_Init to initialize the video system
 */
void VID_Init(void)
{
    refimport_t ri;

    vid_ref = Cvar_Get("vid_ref", "metal", CVAR_ARCHIVE);
    vid_fullscreen = Cvar_Get("vid_fullscreen", "1", CVAR_ARCHIVE);
    vid_gamma = Cvar_Get("vid_gamma", "1.0", CVAR_ARCHIVE);

    /* Set up the renderer import functions */
    ri.Sys_Error = VID_Sys_Error;
    ri.Cmd_AddCommand = Cmd_AddCommand;
    ri.Cmd_RemoveCommand = Cmd_RemoveCommand;
    ri.Cmd_Argc = Cmd_Argc;
    ri.Cmd_Argv = Cmd_Argv;
    ri.Cmd_ExecuteText = Cbuf_ExecuteText;
    ri.Con_Printf = VID_Con_Printf;
    ri.FS_LoadFile = FS_LoadFile;
    ri.FS_FreeFile = FS_FreeFile;
    ri.FS_Gamedir = FS_Gamedir;
    ri.Cvar_Get = Cvar_Get;
    ri.Cvar_Set = Cvar_Set;
    ri.Cvar_SetValue = Cvar_SetValue;
    ri.Vid_GetModeInfo = VID_GetModeInfo;
    ri.Vid_MenuInit = VID_MenuInit;
    ri.Vid_NewWindow = VID_NewWindow;

    /* Get the Metal renderer */
    re = Metal_GetRefAPI(ri);

    if (re.api_version != API_VERSION) {
        Com_Error(ERR_FATAL, "Metal renderer has incompatible API version");
    }

    /* Initialize the renderer */
    if (!re.Init(NULL, NULL)) {
        Com_Error(ERR_FATAL, "Couldn't initialize Metal renderer");
    }

    /* Set viddef so all client code (HUD, menu, console) knows the
       screen dimensions.  Without this, viddef is 0×0 and everything
       draws off-screen. */
    viddef.width = vid_width;
    viddef.height = vid_height;

    Com_Printf("VID_Init: Metal renderer initialized (%dx%d)\n", vid_width, vid_height);
}

void VID_Shutdown(void)
{
    if (re.Shutdown)
        re.Shutdown();
}

void VID_CheckChanges(void)
{
    /* On iOS, video mode doesn't change dynamically */
}

void VID_MenuDraw(void)
{
    /* No video menu on iOS */
}

const char *VID_MenuKey(int k)
{
    return NULL;
}

void IOS_SetVideoSize(int width, int height)
{
    vid_width = width;
    vid_height = height;
    viddef.width = width;
    viddef.height = height;
}
