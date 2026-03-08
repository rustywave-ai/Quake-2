/*
 * Quake2iOS-Bridging-Header.h
 * Exposes C engine functions to Swift code
 *
 * NOTE: We do NOT include the original Quake 2 headers here because they
 * lack include guards and cause redefinition errors. Swift only needs
 * the function signatures below.
 */

#ifndef Quake2iOS_Bridging_Header_h
#define Quake2iOS_Bridging_Header_h

#include <stdint.h>

/* Engine lifecycle — implemented in sys_ios.m */
void Quake2_Init(const char *basePath, const char *savePath);
void Quake2_Frame(int msec);
void Quake2_Pause(void);
void Quake2_Resume(void);
void Quake2_SetCvar(const char *name, const char *value);
void Quake2_MemoryWarning(void);
void Quake2_Shutdown(void);

/* Touch/controller input — implemented in in_ios.m */
void IOS_SetJoystickInput(float forwardmove, float sidemove);
void IOS_SetMovementKeys(int fwd, int back, int left, int right);
void IOS_SetLookInput(float yawDelta, float pitchDelta);
void IOS_KeyEvent(int key, int down);
void IOS_ClearInputState(void);
int  IOS_IsMenuActive(void);
int  IOS_IsConsoleActive(void);
int  IOS_IsInGame(void);
int  IOS_IsInCinematic(void);
int  IOS_GetPausedState(void);
void IOS_MenuTouchAt(int x, int y);
void IOS_SetControllerConnected(int connected);
int  IOS_IsControllerConnected(void);

/* Metal layer bridge — implemented in MetalRenderer.m */
void IOS_SetMetalLayer(void *layer);

/* Video size — implemented in vid_ios.m */
void IOS_SetVideoSize(int32_t width, int32_t height);

#endif /* Quake2iOS_Bridging_Header_h */
