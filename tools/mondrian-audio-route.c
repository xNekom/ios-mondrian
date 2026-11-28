/*
 * Injected into mediaserverd by patch 0512's `mondrianmsguard=1` hook (the
 * crash guard that occupied that path was only an experiment; this replaces
 * it). The kernel/ADSP side is complete, but with VirtualAudio disabled the
 * HAL device has no route and CoreAudio stays on Null_Device, so no PCM ever
 * reaches /dev/mondrian-audio. Ask CoreAudio to make our device the default
 * output from inside the audio server, on a background thread.
 *
 * The iOS SDK here ships only CoreAudioTypes.h, so the four AudioObject calls
 * and their selectors are declared locally (weak: a process without the
 * framework leaves the tuple nil).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

typedef uint32_t AudioObjectID;
typedef int32_t OSStatus;
struct audio_property_address {
	uint32_t selector;
	uint32_t scope;
	uint32_t element;
};

#define FOURCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
    ((uint32_t)(c) << 8) | (uint32_t)(d))
#define kAudioObjectSystemObject             ((AudioObjectID)1)
#define kAudioHardwarePropertyDevices        FOURCC('d', 'e', 'v', '#')
#define kAudioHardwarePropertyDefaultOutputDevice FOURCC('d', 'O', 'u', 't')
#define kAudioObjectPropertyScopeGlobal      FOURCC('g', 'l', 'o', 'b')
#define kAudioObjectPropertyElementMain      FOURCC('m', 'a', 'i', 'n')
#define kAudioDevicePropertyDeviceUID        FOURCC('u', 'i', 'd', ' ')

extern OSStatus AudioObjectGetPropertyDataSize(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t *)
    __attribute__((weak_import));
extern OSStatus AudioObjectGetPropertyData(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t *,
    void *) __attribute__((weak_import));
extern OSStatus AudioObjectSetPropertyData(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t,
    const void *) __attribute__((weak_import));

static void *
mondrian_route_thread(void *unused)
{
	struct audio_property_address devs = {
		kAudioHardwarePropertyDevices,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};
	struct audio_property_address def = {
		kAudioHardwarePropertyDefaultOutputDevice,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};
	struct audio_property_address uidaddr = {
		kAudioDevicePropertyDeviceUID,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};
	uint32_t size = 0, n = 0, i;
	AudioObjectID *ids;
	OSStatus err;

	(void)unused;
	if (AudioObjectGetPropertyDataSize == NULL ||
	    AudioObjectGetPropertyData == NULL ||
	    AudioObjectSetPropertyData == NULL)
		return NULL;
	sleep(12); /* the HAL scan and the ADSP graph start after mediaserverd */
	err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devs,
	    0, NULL, &size);
	syslog(5, "MONDRIAN ROUTE: device list size %u err %d", size, (int)err);
	if (err != 0 || size == 0)
		return NULL;
	ids = malloc(size);
	if (ids == NULL)
		return NULL;
	err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &devs,
	    0, NULL, &size, ids);
	if (err != 0) {
		free(ids);
		return NULL;
	}
	n = size / sizeof(*ids);
	for (i = 0; i < n; i++) {
		CFStringRef uid = NULL;
		uint32_t us = sizeof(uid);

		err = AudioObjectGetPropertyData(ids[i], &uidaddr, 0, NULL,
		    &us, &uid);
		if (err == 0 && uid != NULL) {
			char buf[128];
			int wanted;

			CFStringGetCString(uid, buf, sizeof(buf),
			    kCFStringEncodingUTF8);
			wanted = strcmp(buf, "Speaker") == 0 ||
			    strcmp(buf, "PuffinOutput") == 0;
			syslog(5, "MONDRIAN ROUTE: device %u uid %s%s",
			    (unsigned)ids[i], buf, wanted ? " WANTED" : "");
			if (wanted) {
				err = AudioObjectSetPropertyData(
				    kAudioObjectSystemObject, &def, 0, NULL,
				    sizeof(ids[i]), ids + i);
				syslog(5, "MONDRIAN ROUTE: set default -> %d",
				    (int)err);
				break;
			}
		}
	}
	free(ids);
	return NULL;
}

__attribute__((constructor))
static void
mondrian_route_init(void)
{
	pthread_t thread;

	if (pthread_create(&thread, NULL, mondrian_route_thread, NULL) == 0)
		pthread_detach(thread);
}
