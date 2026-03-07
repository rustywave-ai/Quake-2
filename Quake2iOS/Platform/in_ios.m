/*
 * in_ios.m
 * iOS input system for Quake 2
 * Receives touch/controller input from Swift UI layer
 * Replaces win32/in_win.c
 */

#import <Foundation/Foundation.h>

#include "../../qcommon/qcommon.h"
#include "../../client/client.h"

/* Input state - set by Swift touch/controller handlers */
static float ios_joystick_x = 0.0f;    /* -1 to 1, strafe */
static float ios_joystick_y = 0.0f;    /* -1 to 1, forward/back */
static float ios_look_yaw = 0.0f;      /* delta yaw from touch/controller */
static float ios_look_pitch = 0.0f;    /* delta pitch from touch/controller */

/* These cvars are already defined in cl_main.c */
extern cvar_t *sensitivity;
extern cvar_t *m_pitch;
extern cvar_t *m_yaw;
extern cvar_t *lookstrafe;
/* in_joystick is not defined elsewhere — we provide it */
cvar_t *in_joystick;

/* ================================================================ */
#pragma mark - Interface called from Swift
/* ================================================================ */

void IOS_SetJoystickInput(float forwardmove, float sidemove)
{
    ios_joystick_y = forwardmove;
    ios_joystick_x = sidemove;
}

void IOS_SetLookInput(float yawDelta, float pitchDelta)
{
    ios_look_yaw += yawDelta;
    ios_look_pitch += pitchDelta;
}

void IOS_KeyEvent(int key, int down)
{
    extern void Key_Event(int key, qboolean down, unsigned time);
    Key_Event(key, down ? true : false, Sys_Milliseconds());
}

/*
 * IOS_IsMenuActive
 * Returns 1 if the engine is in menu mode, 0 otherwise.
 * Used by Swift to switch touch behavior (look vs menu tap navigation).
 */
int IOS_IsMenuActive(void)
{
    return (cls.key_dest == key_menu) ? 1 : 0;
}

/*
 * IOS_IsConsoleActive
 * Returns 1 if the console is open.
 */
int IOS_IsConsoleActive(void)
{
    return (cls.key_dest == key_console) ? 1 : 0;
}

/* ================================================================ */
#pragma mark - Engine input interface (IN_*)
/* ================================================================ */

void IN_Init(void)
{
    sensitivity = Cvar_Get("sensitivity", "3", CVAR_ARCHIVE);
    m_pitch = Cvar_Get("m_pitch", "0.022", CVAR_ARCHIVE);
    m_yaw = Cvar_Get("m_yaw", "0.022", CVAR_ARCHIVE);
    lookstrafe = Cvar_Get("lookstrafe", "0", 0);

    Com_Printf("IN_Init: iOS touch input initialized\n");
}

void IN_Shutdown(void)
{
    /* Nothing to clean up */
}

void IN_Commands(void)
{
    /* Button events are dispatched directly via IOS_KeyEvent */
}

void IN_Frame(void)
{
    /* Nothing needed per-frame */
}

void IN_Activate(qboolean active)
{
    /* Nothing to do on iOS */
    (void)active;
}

/*
 * IN_Move
 * Called from CL_SendCmd to get movement input
 * Translates touch/controller state into usercmd_t
 */
void IN_Move(usercmd_t *cmd)
{
    float sens = sensitivity->value;

    /* Apply joystick movement - scale to Q2's expected range (±400 is full speed) */
    cmd->forwardmove += (short)(ios_joystick_y * 400.0f);
    cmd->sidemove += (short)(ios_joystick_x * 400.0f);

    /* Apply look input */
    if (ios_look_yaw != 0.0f || ios_look_pitch != 0.0f) {
        cl.viewangles[YAW] -= ios_look_yaw * sens * m_yaw->value;
        cl.viewangles[PITCH] += ios_look_pitch * sens * m_pitch->value;

        /* Clamp pitch */
        if (cl.viewangles[PITCH] > 80.0f)
            cl.viewangles[PITCH] = 80.0f;
        if (cl.viewangles[PITCH] < -70.0f)
            cl.viewangles[PITCH] = -70.0f;

        /* Reset deltas - they're consumed */
        ios_look_yaw = 0.0f;
        ios_look_pitch = 0.0f;
    }
}
