/*
 * Probe CoreAudio's device list from a process whose stdout is the kernel
 * ring. Run through tools/wsl/run-test.sh. This is a diagnostic: it tells
 * whether kAudioHardwarePropertyDevices is empty in general or only inside
 * mediaserverd (where the HAL plug-in measured size=0).
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t AudioObjectID;
typedef int32_t OSStatus;
struct pa { uint32_t selector, scope, element; };
#define FOURCC(a,b,c,d) (((uint32_t)(a)<<24)|((uint32_t)(b)<<16)|((uint32_t)(c)<<8)|(uint32_t)(d))
#define SYS ((AudioObjectID)1)
#define DEVICES FOURCC('d','e','v','#')
#define DEFAULT_OUT FOURCC('d','O','u','t')
#define UIDPROP FOURCC('u','i','d',' ')
#define GLOBAL FOURCC('g','l','o','b')

typedef OSStatus (*size_fn)(AudioObjectID, const struct pa *, uint32_t,
    const void *, uint32_t *);
typedef OSStatus (*data_fn)(AudioObjectID, const struct pa *, uint32_t,
    const void *, uint32_t *, void *);

int
main(void)
{
	struct pa devs = { DEVICES, GLOBAL, 0 };
	struct pa uidp = { UIDPROP, GLOBAL, 0 };
	size_fn get_size;
	data_fn get_data;
	void *h;
	uint32_t size = 0, i, n;
	AudioObjectID *ids;
	OSStatus e;

	printf("MONDRIAN AUDIO PROBE: start\n");
	h = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
	    RTLD_LAZY);
	if (h == NULL)
		h = dlopen("/usr/lib/libAudioObject.dylib", RTLD_LAZY);
	printf("MONDRIAN AUDIO PROBE: dlopen %d\n", h != NULL);
	get_size = (size_fn)dlsym(h ? h : RTLD_DEFAULT,
	    "AudioObjectGetPropertyDataSize");
	get_data = (data_fn)dlsym(h ? h : RTLD_DEFAULT,
	    "AudioObjectGetPropertyData");
	printf("MONDRIAN AUDIO PROBE: dlsym %d %d\n", get_size != NULL,
	    get_data != NULL);
	if (get_size == NULL || get_data == NULL)
		return 0;
	e = get_size(SYS, &devs, 0, NULL, &size);
	printf("MONDRIAN AUDIO PROBE: device list size=%u err=%d\n", size,
	    (int)e);
	if (e != 0 || size == 0)
		return 0;
	ids = malloc(size);
	if (ids == NULL)
		return 0;
	e = get_data(SYS, &devs, 0, NULL, &size, ids);
	printf("MONDRIAN AUDIO PROBE: get data err=%d\n", (int)e);
	n = size / sizeof(*ids);
	for (i = 0; i < n; i++) {
		uint32_t us = 0;
		char buf[128] = { 0 };

		e = get_data(ids[i], &uidp, 0, NULL, &us, buf);
		printf("MONDRIAN AUDIO PROBE: device %u uid='%s' err=%d\n",
		    (unsigned)ids[i], buf, (int)e);
	}
	free(ids);
	printf("MONDRIAN AUDIO PROBE: done\n");
	return 0;
}
