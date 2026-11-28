/*
 * Injected into mediaserverd by patch 0512 (`mondrianmsguard=1`).
 *
 * CoreAudio's global kAudioHardwarePropertyDevices list is empty on this
 * port, but the Mondrian HAL plug-in is registered and exposes its four
 * devices through kAudioPlugInPropertyDeviceList. Measured 2026-11-28: the
 * default output can be set directly by AudioObjectID even though the list
 * is empty (AudioObjectSetPropertyData -> 0, default 50 -> 41). This thread
 * discovers the Speaker's ID the same way a diagnostic probe did and sets
 * it as the default output, so an app that plays sound reaches the kernel
 * node instead of Null_Device.
 *
 * CoreFoundation only at constructor time (Foundation aborts this early);
 * the work runs on a detached pthread after a short delay. Log to the console
 * ring through printf: mediaserverd's own files are sandboxed.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef uint32_t AudioObjectID;
typedef int32_t OSStatus;
struct audio_property_address {
	uint32_t selector, scope, element;
};
#define FOURCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
    ((uint32_t)(c) << 8) | (uint32_t)(d))
#define kAudioObjectSystemObject             ((AudioObjectID)1)
#define kAudioHardwarePropertyDevices        FOURCC('d', 'e', 'v', '#')
#define kAudioHardwarePropertyDefaultOutputDevice FOURCC('d', 'O', 'u', 't')
#define kAudioObjectPropertyScopeGlobal      FOURCC('g', 'l', 'o', 'b')
#define kAudioObjectPropertyOwnedObjects     FOURCC('o', 'w', 'n', 'd')
#define kAudioObjectPropertyName             FOURCC('l', 'n', 'a', 'm')
#define kAudioDevicePropertyDeviceUID        FOURCC('u', 'i', 'd', ' ')
#define PLUG_BUNDLE_ID                       "app.mondrian.audio.hal"

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

static uint32_t
find_speaker(void)
{
	struct audio_property_address owned = {
		kAudioObjectPropertyOwnedObjects,
		kAudioObjectPropertyScopeGlobal, 0
	};
	struct audio_property_address devlist = {
		kAudioHardwarePropertyDevices,
		kAudioObjectPropertyScopeGlobal, 0
	};
	struct audio_property_address nameaddr = {
		kAudioObjectPropertyName,
		kAudioObjectPropertyScopeGlobal, 0
	};
	struct audio_property_address uidaddr = {
		kAudioDevicePropertyDeviceUID,
		kAudioObjectPropertyScopeGlobal, 0
	};
	uint32_t size = 0, i, j;
	AudioObjectID *plugins, *devices;
	OSStatus err;

	if (get_size(kAudioObjectSystemObject, &owned, 0, NULL, &size) != 0 ||
	    size == 0)
		return 0;
	plugins = malloc(size);
	if (plugins == NULL)
		return 0;
	err = get_data(kAudioObjectSystemObject, &owned, 0, NULL, &size, plugins);
	if (err != 0) {
		free(plugins);
		return 0;
	}
	for (i = 0; i < size / sizeof(*plugins); i++) {
		CFStringRef name = NULL;
		char buf[128];

		uint32_t ns = sizeof(name);
		if (get_data(plugins[i], &nameaddr, 0, NULL, &ns, &name) != 0 ||
		    name == NULL)
			continue;
		buf[0] = 0;
		CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
		if (strcmp(buf, PLUG_BUNDLE_ID) != 0)
			continue;
		printf("MONDRIAN ROUTE: plugin %u found\n", (unsigned)plugins[i]);
		ns = 0;
		if (get_size(plugins[i], &devlist, 0, NULL, &ns) != 0 || ns == 0)
			break;
		devices = malloc(ns);
		if (devices == NULL)
			break;
		err = get_data(plugins[i], &devlist, 0, NULL, &ns, devices);
		if (err == 0) {
			for (j = 0; j < ns / sizeof(*devices); j++) {
				CFStringRef uid = NULL;
				char u[64];

				uint32_t us = sizeof(uid);
				if (get_data(devices[j], &uidaddr, 0, NULL, &us,
				    &uid) != 0 || uid == NULL)
					continue;
				u[0] = 0;
				CFStringGetCString(uid, u, sizeof(u),
				    kCFStringEncodingUTF8);
				printf("MONDRIAN ROUTE: device %u uid %s\n",
				    (unsigned)devices[j], u);
				if (strcmp(u, "Speaker") == 0) {
					AudioObjectID found = devices[j];

					free(devices);
					free(plugins);
					return found;
				}
			}
		}
		free(devices);
		break;
	}
	free(plugins);
	return 0;
}

static void *
mondrian_route_thread(void *unused)
{
	struct audio_property_address def = {
		kAudioHardwarePropertyDefaultOutputDevice,
		kAudioObjectPropertyScopeGlobal, 0
	};
	void *handle;
	uint32_t speaker, current = 0, size = sizeof(current);
	OSStatus err;

	(void)unused;
	handle = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
	    RTLD_LAZY);
	if (handle == NULL)
		handle = dlopen("/usr/lib/libAudioObject.dylib", RTLD_LAZY);
	get_size = (get_size_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectGetPropertyDataSize");
	get_data = (get_data_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectGetPropertyData");
	set_data = (set_data_fn)dlsym(handle != NULL ? handle : RTLD_DEFAULT,
	    "AudioObjectSetPropertyData");
	printf("MONDRIAN ROUTE: thread start dlopen=%d syms=%d%d%d\n",
	    handle != NULL, get_size != NULL, get_data != NULL, set_data != NULL);
	if (get_size == NULL || get_data == NULL || set_data == NULL)
		return NULL;
	/*
	 * The HAL scan starts well after mediaserverd: a probe run a minute
	 * into the boot sees the plug-in, while a 6 s delay does not. Retry
	 * until the plug-in object shows up, logging the list size so a
	 * failure names which step is empty.
	 */
	for (unsigned try = 0; try < 12; try++) {
		sleep(5);
		{
			struct audio_property_address owned = {
				kAudioObjectPropertyOwnedObjects,
				kAudioObjectPropertyScopeGlobal, 0
			};
			uint32_t n = 0;

			if (get_size(kAudioObjectSystemObject, &owned, 0, NULL,
			    &n) != 0)
				n = 0;
			printf("MONDRIAN ROUTE: try %u owned=%u\n", try, n);
		}
		speaker = find_speaker();
		if (speaker != 0)
			break;
	}
	printf("MONDRIAN ROUTE: speaker id=%u\n", (unsigned)speaker);
	if (speaker == 0)
		return NULL;
	err = get_data(kAudioObjectSystemObject, &def, 0, NULL, &size, &current);
	printf("MONDRIAN ROUTE: default before=%u err=%d\n", (unsigned)current,
	    (int)err);
	err = set_data(kAudioObjectSystemObject, &def, 0, NULL, sizeof(speaker),
	    &speaker);
	printf("MONDRIAN ROUTE: set default -> %d\n", (int)err);
	current = 0; size = sizeof(current);
	err = get_data(kAudioObjectSystemObject, &def, 0, NULL, &size, &current);
	printf("MONDRIAN ROUTE: default after=%u err=%d\n", (unsigned)current,
	    (int)err);
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
