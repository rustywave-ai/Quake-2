/*
 * in_ios.m
 * iOS input system for Quake 2
 * Receives touch/controller input from Swift UI layer
 * Replaces win32/in_win.c
 */

#import <Foundation/Foundation.h>

#include "../../qcommon/qcommon.h"
#include "../../client/client.h"

/* Controller state — determines whether menu cursor indicators are shown */
static int ios_controller_connected = 0;

/* Analog joystick input — set by Swift, consumed by IN_Move */
static float ios_joystick_x = 0.0f;    /* -1 to 1, strafe */
static float ios_joystick_y = 0.0f;    /* -1 to 1, forward/back */

/* Look input — accumulated deltas from touch/controller */
static float ios_look_yaw = 0.0f;
static float ios_look_pitch = 0.0f;

/* Movement command state — tracks which direction commands are active */
static int move_fwd_down = 0;
static int move_back_down = 0;
static int move_left_down = 0;
static int move_right_down = 0;

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

/*
 * IOS_SetJoystickInput
 * Sets analog joystick values for direct movement injection in IN_Move.
 */
void IOS_SetJoystickInput(float forwardmove, float sidemove)
{
    ios_joystick_y = forwardmove;
    ios_joystick_x = sidemove;
}

/*
 * IOS_SetMovementKeys
 * Called from Swift with D-pad state derived from joystick thresholds.
 * Sends +forward/-forward etc. directly to the command buffer on state
 * transitions. This is the same path as typing the command in the console.
 */
void IOS_SetMovementKeys(int fwd, int back, int left, int right)
{
    if (fwd != move_fwd_down) {
        move_fwd_down = fwd;
        Cbuf_AddText(fwd ? "+forward\n" : "-forward\n");
    }
    if (back != move_back_down) {
        move_back_down = back;
        Cbuf_AddText(back ? "+back\n" : "-back\n");
    }
    if (left != move_left_down) {
        move_left_down = left;
        Cbuf_AddText(left ? "+moveleft\n" : "-moveleft\n");
    }
    if (right != move_right_down) {
        move_right_down = right;
        Cbuf_AddText(right ? "+moveright\n" : "-moveright\n");
    }
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

/*
 * IOS_IsInGame
 * Returns 1 if the player is in an actual game (not attract/demo loop).
 * Used by Swift to show action buttons only during real gameplay.
 */
int IOS_IsInGame(void)
{
    return (cls.state == ca_active && !cl.attractloop) ? 1 : 0;
}

/*
 * IOS_IsInCinematic
 * Returns 1 if the engine is playing a cinematic (.cin cutscene).
 * Used by Swift to hide game controls during cutscenes.
 */
int IOS_IsInCinematic(void)
{
    return (cl.cinematictime > 0) ? 1 : 0;
}

/*
 * IOS_SetControllerConnected / IOS_IsControllerConnected
 * Tracks whether an MFi/DualSense controller is connected.
 * When no controller is present (touch-only), menu cursor indicators are hidden.
 */
void IOS_SetControllerConnected(int connected)
{
    ios_controller_connected = connected;
}

int IOS_IsControllerConnected(void)
{
    return ios_controller_connected;
}

/*
 * IOS_MenuTouchAt
 * Directly selects the menu item at the given screen coordinates.
 * Called from Swift touch handling instead of sending UP/DOWN/ENTER keys.
 */
void IOS_MenuTouchAt(int x, int y)
{
    extern void M_TouchEvent(int x, int y);
    M_TouchEvent(x, y);
}

/*
 * IOS_ClearInputState
 * Zeros all accumulated input and releases any stuck keys.
 * Called on game state transitions (menu→game) to prevent stale input.
 */
void IOS_ClearInputState(void)
{
    extern void Key_ClearStates(void);

    ios_look_yaw = 0.0f;
    ios_look_pitch = 0.0f;
    ios_joystick_x = 0.0f;
    ios_joystick_y = 0.0f;

    /* Release any active movement commands */
    if (move_fwd_down) { Cbuf_AddText("-forward\n"); move_fwd_down = 0; }
    if (move_back_down) { Cbuf_AddText("-back\n"); move_back_down = 0; }
    if (move_left_down) { Cbuf_AddText("-moveleft\n"); move_left_down = 0; }
    if (move_right_down) { Cbuf_AddText("-moveright\n"); move_right_down = 0; }

    Key_ClearStates();
}

/*
 * IOS_GetPausedState
 * Returns 1 if the game is paused.
 */
int IOS_GetPausedState(void)
{
    return (int)Cvar_VariableValue("paused");
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

    /* Bind AUX keys for touch buttons (crouch, weapon switch) */
    Cbuf_AddText("bind AUX1 +movedown\n");
    Cbuf_AddText("bind AUX2 weapnext\n");
    Cbuf_AddText("bind AUX3 weapprev\n");

    /* Bind AUX keys for D-pad movement buttons */
    Cbuf_AddText("bind AUX4 +forward\n");
    Cbuf_AddText("bind AUX5 +back\n");
    Cbuf_AddText("bind AUX6 +moveleft\n");
    Cbuf_AddText("bind AUX7 +moveright\n");

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
 * Called from CL_CreateCmd to get movement input.
 * Provides both analog joystick movement (direct cmd injection)
 * and look input (viewangles).
 *
 * Movement also flows through +forward/+back/+moveleft/+moveright
 * commands sent by IOS_SetMovementKeys → Cbuf → CL_BaseMove.
 * The direct injection here is a redundant path for reliability.
 */
void IN_Move(usercmd_t *cmd)
{
    float sens = sensitivity->value;

    /* Apply analog joystick movement — direct injection.
       Scale to Q2's expected range (±400 is full speed with cl_run=1). */
    if (ios_joystick_y != 0.0f || ios_joystick_x != 0.0f) {
        cmd->forwardmove += (short)(ios_joystick_y * 400.0f);
        cmd->sidemove += (short)(ios_joystick_x * 400.0f);
    }

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
