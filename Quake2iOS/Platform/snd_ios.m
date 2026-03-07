/*
 * snd_ios.m
 * iOS audio backend for Quake 2
 * Implements SNDDMA_* interface using AVAudioEngine
 * Replaces win32/snd_win.c
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "../../qcommon/qcommon.h"
#include "../../client/snd_loc.h"

/* The existing snd_dma.c mixing code writes to this DMA buffer.
 * We feed it to AVAudioEngine via an installTapOnBus or
 * AVAudioSourceNode render callback. */

static AVAudioEngine *audioEngine = nil;
static AVAudioSourceNode *sourceNode = nil;

/* DMA buffer that the Q2 mixer writes into */
#define IOS_DMA_BUFFER_SIZE (65536)
static unsigned char ios_dma_buffer[IOS_DMA_BUFFER_SIZE];
static int ios_dma_pos = 0;

/* Audio format - 22050Hz stereo 16-bit matches Q2 defaults */
#define IOS_SAMPLE_RATE 22050
#define IOS_CHANNELS 2
#define IOS_SAMPLE_BITS 16

/*
 * SNDDMA_Init
 * Called by S_Init in snd_dma.c
 * Sets up the DMA buffer info so the mixer knows where to write
 */
qboolean SNDDMA_Init(void)
{
    NSError *error = nil;

    /* Configure audio session */
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error) {
        Com_Printf("SNDDMA_Init: failed to set audio session category: %s\n",
                    [[error localizedDescription] UTF8String]);
        return false;
    }
    [session setActive:YES error:&error];
    if (error) {
        Com_Printf("SNDDMA_Init: failed to activate audio session: %s\n",
                    [[error localizedDescription] UTF8String]);
        return false;
    }

    /* Set up DMA buffer info for the Q2 mixer */
    memset(ios_dma_buffer, 0, sizeof(ios_dma_buffer));

    dma.samplebits = IOS_SAMPLE_BITS;
    dma.speed = IOS_SAMPLE_RATE;
    dma.channels = IOS_CHANNELS;
    dma.samples = IOS_DMA_BUFFER_SIZE / (IOS_SAMPLE_BITS / 8);
    dma.samplepos = 0;
    dma.submission_chunk = 1;
    dma.buffer = ios_dma_buffer;

    ios_dma_pos = 0;

    /* Create AVAudioEngine with a source node that reads from our DMA buffer */
    audioEngine = [[AVAudioEngine alloc] init];

    AVAudioFormat *format = [[AVAudioFormat alloc]
                             initWithCommonFormat:AVAudioPCMFormatInt16
                             sampleRate:IOS_SAMPLE_RATE
                             channels:IOS_CHANNELS
                             interleaved:YES];

    sourceNode = [[AVAudioSourceNode alloc]
                  initWithFormat:format
                  renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                        AVAudioFrameCount frameCount,
                                        AudioBufferList *outputData) {
        /* Copy from the DMA ring buffer into the audio output buffer */
        int bytesPerFrame = IOS_CHANNELS * (IOS_SAMPLE_BITS / 8);
        int bytesNeeded = frameCount * bytesPerFrame;
        unsigned char *dst = (unsigned char *)outputData->mBuffers[0].mData;
        int bufferSize = IOS_DMA_BUFFER_SIZE;

        for (int i = 0; i < bytesNeeded; i++) {
            dst[i] = ios_dma_buffer[ios_dma_pos % bufferSize];
            ios_dma_pos++;
        }

        outputData->mBuffers[0].mDataByteSize = bytesNeeded;
        *isSilence = NO;

        return noErr;
    }];

    [audioEngine attachNode:sourceNode];
    [audioEngine connect:sourceNode
                      to:audioEngine.mainMixerNode
                  format:format];

    [audioEngine startAndReturnError:&error];
    if (error) {
        Com_Printf("SNDDMA_Init: failed to start audio engine: %s\n",
                    [[error localizedDescription] UTF8String]);
        audioEngine = nil;
        sourceNode = nil;
        return false;
    }

    Com_Printf("SNDDMA_Init: AVAudioEngine started (%dHz, %dch, %dbit)\n",
               IOS_SAMPLE_RATE, IOS_CHANNELS, IOS_SAMPLE_BITS);

    return true;
}

/*
 * SNDDMA_GetDMAPos
 * Returns the current sample position in the DMA buffer
 */
int SNDDMA_GetDMAPos(void)
{
    return ios_dma_pos / (IOS_SAMPLE_BITS / 8);
}

/*
 * SNDDMA_Shutdown
 * Shuts down the audio system
 */
void SNDDMA_Shutdown(void)
{
    if (audioEngine) {
        [audioEngine stop];
        audioEngine = nil;
        sourceNode = nil;
    }

    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];

    Com_Printf("SNDDMA_Shutdown: audio engine stopped\n");
}

/*
 * SNDDMA_BeginPainting
 * Called before the mixer writes to the DMA buffer
 */
void SNDDMA_BeginPainting(void)
{
    /* Nothing needed - the DMA buffer is always available */
}

/*
 * SNDDMA_Submit
 * Called after the mixer finishes writing to the DMA buffer
 */
void SNDDMA_Submit(void)
{
    /* The AVAudioSourceNode render block reads from the buffer automatically.
     * Nothing to do here. */
}
