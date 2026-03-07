/*
 * cd_ios.c
 * iOS CD audio stub for Quake 2
 * Replaces win32/cd_win.c
 * CD audio is not applicable on iOS - all functions are stubs.
 */

#include "../../qcommon/qcommon.h"

void CDAudio_Play(int track, qboolean looping)
{
    (void)track;
    (void)looping;
}

void CDAudio_Stop(void)
{
}

void CDAudio_Resume(void)
{
}

void CDAudio_Update(void)
{
}

int CDAudio_Init(void)
{
    return 0;
}

void CDAudio_Shutdown(void)
{
}
