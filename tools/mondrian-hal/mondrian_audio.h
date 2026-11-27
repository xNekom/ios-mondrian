/*
 * /dev/mondrian-audio: the user/kernel ABI between MondrianAudio.driver (the CoreAudio HAL
 * plug-in in mediaserverd) and the kernel sink (bsd/dev/mondrian_audio.c, patches/xnu/0241+).
 * The kernel keeps its own copy of these numbers (it has no userland headers): change both.
 *
 * Model: HackiOS sys/redwood_audio.h (external/hackios-xnu-userland, MIT).
 *
 *   write()  whole frames, S16LE, 2 channels (left, right), 48000 frames/s. Never blocks (the
 *            writer is the HAL real-time I/O thread). The return value is the number of bytes
 *            the kernel took; the rest is dropped. ENODEV: no sink is running (no ADSP graph):
 *            the plug-in counts the frames as dropped and goes on.
 *   ioctl    MONDRIAN_AUDIO_SET_VOLUME: the HAL volume control, in 1/8 dB below the kernel's
 *            maximum (the kernel maximum is a safe, low level: see the kernel limiter).
 *            MONDRIAN_AUDIO_GET_STATS: counters for scripts/audio/phone-test.sh.
 */
#ifndef MONDRIAN_AUDIO_H
#define MONDRIAN_AUDIO_H

#include <stdint.h>
#include <sys/ioccom.h>

#define MONDRIAN_AUDIO_DEVICE    "/dev/mondrian-audio"
#define MONDRIAN_AUDIO_RATE      48000
#define MONDRIAN_AUDIO_CHANNELS  2
#define MONDRIAN_AUDIO_FRAME     4       /* bytes per frame */

struct mondrian_audio_volume {
	uint32_t below;                 /* 1/8 dB below the kernel maximum (0243: stored, not applied yet) */
	uint32_t muted;                 /* 1: iOS volume 0 */
};

struct mondrian_audio_stats {
	uint64_t frames_in;             /* frames written by user space */
	uint64_t frames_dropped;        /* frames the sink did not take */
	uint64_t frames_played;         /* frames the sink gave to the DSP */
	uint32_t state;                 /* MONDRIAN_AUDIO_STATE_* */
	uint32_t peak_in;               /* peak |sample| written since the last GET_STATS */
	uint32_t peak_out;              /* peak |sample| after the limiter since the last GET_STATS */
	uint32_t limiter_gain_q15;      /* limiter gain now, 32768 = 0 dB */
};

#define MONDRIAN_AUDIO_STATE_NOSINK      0       /* the device exists, no sink: samples are dropped */
#define MONDRIAN_AUDIO_STATE_IDLE        1       /* a sink exists, not running */
#define MONDRIAN_AUDIO_STATE_RUNNING     2       /* the graph runs, samples go to the DSP */
#define MONDRIAN_AUDIO_STATE_FAILED      3       /* the sink stopped after an error */

#define MONDRIAN_AUDIO_SET_VOLUME        _IOW('m', 1, struct mondrian_audio_volume)
#define MONDRIAN_AUDIO_GET_STATS         _IOR('m', 2, struct mondrian_audio_stats)
/*
 * 0246: the output route of the Speaker stream. SPEAKER: both TFA9874 amps (stereo); RECEIVER: the
 * top amp only in its "receiver" profile (the earpiece; the kernel plays (L + R) / 2). A change
 * stops the amps; the next non-silent write starts the new route. Also: sysctl kern.mondrian_audio_route.
 */
#define MONDRIAN_AUDIO_ROUTE_SPEAKER     1u
#define MONDRIAN_AUDIO_ROUTE_RECEIVER    2u
#define MONDRIAN_AUDIO_SET_ROUTE         _IOW('m', 3, uint32_t)
/* 0509: a line for the console ring; mediaserverd's stderr does not reach it. */
#define MONDRIAN_AUDIO_LOG               _IOW('m', 4, char[128])

#endif
