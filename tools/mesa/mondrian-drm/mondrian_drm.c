/*
 * The libdrm of xf86drm.h (see there): Linux's DRM requests to MondrianGPU as
 * calls of its IOKit user client. A request's number, the low byte of the
 * ioctl code, is the call's selector; its structure goes in and comes back as
 * it is, because the kernel reads and writes Linux's own
 * include/uapi/drm/msm_drm.h structures.
 *
 * freedreno knows its device by a file descriptor. It gets one that means
 * nothing (/dev/null): there is one GPU and one connection to it in a process,
 * and the connection, not the descriptor, is what the requests go to.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <IOKit/IOKitLib.h>

#include "xf86drm.h"

#define MONDIAN_GPU_SERVICE	"MondrianGPU"

static io_connect_t connection;
static int connection_fd = -1;

int
drmOpenWithType(const char *name, const char *busid, int type)
{
	io_service_t service;

	(void)busid;
	(void)type;
	if (strcmp(name, "msm") != 0) {
		errno = ENODEV;
		return -1;
	}
	if (connection_fd >= 0) {
		return dup(connection_fd);
	}
	service = IOServiceGetMatchingService(0,
	    IOServiceMatching(MONDIAN_GPU_SERVICE));
	if (service == 0) {
		errno = ENODEV;
		return -1;
	}
	if (IOServiceOpen(service, mach_task_self(), 0, &connection) != 0) {
		IOObjectRelease(service);
		errno = ENXIO;
		return -1;
	}
	IOObjectRelease(service);
	connection_fd = open("/dev/null", O_RDWR);
	if (connection_fd < 0) {
		IOServiceClose(connection);
		connection = 0;
		return -1;
	}
	return dup(connection_fd);
}

/* One request; the kernel's answer comes back in the same structure. */
static int
call(unsigned number, void *data, size_t size)
{
	size_t returned = size;
	kern_return_t result = IOConnectCallStructMethod(connection, number,
	    data, size, data, &returned);

	switch (result) {
	case 0:
		return 0;
	case kIOReturnNoMemory:
		return ENOMEM;
	case kIOReturnBadArgument:
		return EINVAL;
	case kIOReturnTimeout:
		return ETIMEDOUT;
	case kIOReturnBusy:
		return EBUSY;
	case kIOReturnNotFound:
		return ENOENT;
	case kIOReturnNotReady:
		return EAGAIN;
	case kIOReturnUnsupported:
		return ENOSYS;
	default:
		return EIO;
	}
}

int
drmIoctl(int fd, unsigned long request, void *arg)
{
	int error = call((unsigned)(request & 0xff), arg, IOCPARM_LEN(request));

	(void)fd;
	if (error != 0) {
		errno = error;
		return -1;
	}
	return 0;
}

/*
 * These two return -errno rather than -1 with errno, as libdrm's do: freedreno
 * compares the answer of DRM_MSM_WAIT_FENCE with -ETIMEDOUT
 * (src/freedreno/drm/msm/msm_pipe.c), which only that convention makes match.
 */
int
drmCommandWrite(int fd, unsigned long index, const void *data,
    unsigned long size)
{
	(void)fd;
	return -call((unsigned)(DRM_COMMAND_BASE + index),
	    (void *)(uintptr_t)data, size);
}

int
drmCommandWriteRead(int fd, unsigned long index, void *data,
    unsigned long size)
{
	(void)fd;
	return -call((unsigned)(DRM_COMMAND_BASE + index), data, size);
}

/*
 * The driver calls itself what Linux's is called, and is of the version whose
 * interface it has: 1.7, buffers at addresses the kernel chooses and tells
 * ("softpin"), no cached-coherent flag probe, no VM_BIND. Reporting a newer
 * minor version would make freedreno use interfaces the kernel does not have.
 */
drmVersionPtr
drmGetVersion(int fd)
{
	drmVersionPtr version = calloc(1, sizeof(*version));

	(void)fd;
	if (version != NULL) {
		version->version_major = 1;
		version->version_minor = 7;
		version->name = strdup("msm");
		version->name_len = 3;
		version->date = strdup("");
		version->desc = strdup("Adreno 730 on Darwin");
		version->desc_len = (int)strlen(version->desc);
	}
	return version;
}

void
drmFreeVersion(drmVersionPtr version)
{
	if (version != NULL) {
		free(version->name);
		free(version->date);
		free(version->desc);
		free(version);
	}
}

/*
 * No capability is present on this port: freedreno asks for syncobj support
 * here and gets a no, so it never waits on a syncobj of ours.
 */
int
drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	(void)fd;
	(void)capability;
	*value = 0;
	return 0;
}

void *
mondrian_drm_map(int fd, uint32_t handle, uint64_t size)
{
	mach_vm_address_t address = 0;
	mach_vm_size_t mapped = 0;

	(void)fd;
	(void)size;
	/*
	 * No mmap() on a device here: the kernel's user client maps the whole
	 * buffer into this task and hands back the address, and the type of the
	 * client memory is the buffer's GEM handle
	 * (MondrianGPUUserClient::clientMemoryForType). Linux maps buffers
	 * write-combined and freedreno depends on that; here the memory belongs
	 * to the kernel's driver and this mapping is as the kernel made it.
	 */
	if (IOConnectMapMemory64(connection, handle, mach_task_self(),
	    &address, &mapped, kIOMapAnywhere) != 0) {
		return (void *)-1;		/* mmap()'s MAP_FAILED */
	}
	return (void *)(uintptr_t)address;
}

void
mondrian_drm_unmap(int fd, uint32_t handle, void *address)
{
	(void)fd;
	IOConnectUnmapMemory64(connection, handle, mach_task_self(),
	    (mach_vm_address_t)(uintptr_t)address);
}

/*
 * The IOSurface request is not here yet: the kernel's user client has no
 * request 0x7e, and this port presents nothing to a window server yet. When it
 * does, it is one more request number whose structure describes a surface (its
 * IOSurface ID in, size/offset/row bytes/format out; topaz's redwood-drm is
 * the model) and it goes here, because freedreno hands the ID of a surface
 * around where Linux hands around the file descriptor of a buffer:
 * drmPrimeFDToHandle() and drmPrimeHandleToFD() are the two calls it replaces.
 * Until then nothing imports a buffer it did not allocate itself.
 */

static int
none(void)
{
	errno = ENOSYS;
	return -1;
}

/* Buffers and fences as file descriptors, for sharing them: none of that here. */
#define NONE(name, ...) int name(__VA_ARGS__) { return none(); }
NONE(drmPrimeHandleToFD, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t handle, __attribute__((unused)) uint32_t flags,
    __attribute__((unused)) int *prime_fd)
NONE(drmPrimeFDToHandle, __attribute__((unused)) int fd,
    __attribute__((unused)) int prime_fd, __attribute__((unused)) uint32_t *handle)
NONE(drmSyncobjCreate, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t flags, __attribute__((unused)) uint32_t *handle)
NONE(drmSyncobjDestroy, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t handle)
NONE(drmSyncobjReset, __attribute__((unused)) int fd,
    __attribute__((unused)) const uint32_t *handles,
    __attribute__((unused)) uint32_t count)
NONE(drmSyncobjFDToHandle, __attribute__((unused)) int fd,
    __attribute__((unused)) int obj_fd, __attribute__((unused)) uint32_t *handle)
NONE(drmSyncobjHandleToFD, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t handle, __attribute__((unused)) int *obj_fd)
NONE(drmSyncobjImportSyncFile, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t handle,
    __attribute__((unused)) int sync_file_fd)
NONE(drmSyncobjExportSyncFile, __attribute__((unused)) int fd,
    __attribute__((unused)) uint32_t handle,
    __attribute__((unused)) int *sync_file_fd)
