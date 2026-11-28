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
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define ROUTE_LOG "/var/mobile/audio-route.log"

static void
route_log(const char *fmt, ...)
{
	char line[256];
	va_list ap;
	FILE *f;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	f = fopen(ROUTE_LOG, "a");
	if (f == NULL)
		return;
	fprintf(f, "%s\n", line);
	fclose(f);
}

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
#define kAudioObjectPropertyElementMain      0  /* kAudioObjectPropertyElementMaster */
#define kAudioDevicePropertyDeviceUID        FOURCC('u', 'i', 'd', ' ')

typedef OSStatus (*get_size_fn)(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t *);
typedef OSStatus (*get_data_fn)(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t *,
    void *);
typedef OSStatus (*set_data_fn)(AudioObjectID,
    const struct audio_property_address *, uint32_t, const void *, uint32_t,
    const void *);
static get_size_fn get_size;
static get_data_fn get_data;
static set_data_fn set_data;

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
	void *handle;
	AudioObjectID *ids;
	OSStatus err;

	(void)unused;
	route_log("route thread start");
	handle = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
	    RTLD_LAZY);
	if (handle == NULL)
		handle = dlopen("/usr/lib/libAudioObject.dylib", RTLD_LAZY);
	route_log("dlopen %d", handle != NULL);
	get_size = (get_size_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectGetPropertyDataSize");
	get_data = (get_data_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectGetPropertyData");
	set_data = (set_data_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectSetPropertyData");
	route_log("dlsym %d %d %d", get_size != NULL, get_data != NULL,
	    set_data != NULL);
	if (get_size == NULL || get_data == NULL || set_data == NULL)
		return NULL;
	sleep(12); /* the HAL scan and the ADSP graph start after mediaserverd */
	err = get_size(kAudioObjectSystemObject, &devs,
	    0, NULL, &size);
	route_log("MONDRIAN ROUTE: device list size %u err %d", size, (int)err);
	if (err != 0 || size == 0)
		return NULL;
	ids = malloc(size);
	if (ids == NULL)
		return NULL;
	err = get_data(kAudioObjectSystemObject, &devs,
	    0, NULL, &size, ids);
	if (err != 0) {
		free(ids);
		return NULL;
	}
	n = size / sizeof(*ids);
	for (i = 0; i < n; i++) {
		CFStringRef uid = NULL;
		uint32_t us = sizeof(uid);

		err = get_data(ids[i], &uidaddr, 0, NULL,
		    &us, &uid);
		if (err == 0 && uid != NULL) {
			char buf[128];
			int wanted;

			CFStringGetCString(uid, buf, sizeof(buf),
			    kCFStringEncodingUTF8);
			wanted = strcmp(buf, "Speaker") == 0 ||
			    strcmp(buf, "PuffinOutput") == 0;
			route_log("MONDRIAN ROUTE: device %u uid %s%s",
			    (unsigned)ids[i], buf, wanted ? " WANTED" : "");
			if (wanted) {
				err = set_data(
				    kAudioObjectSystemObject, &def, 0, NULL,
				    sizeof(ids[i]), ids + i);
				route_log("MONDRIAN ROUTE: set default -> %d", (int)err);
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
