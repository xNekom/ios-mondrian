/*
 * The libdrm Mesa's freedreno is built against on this port: what freedreno
 * takes from libdrm's xf86drm.h on a system without Linux's DRM. The
 * declarations are here, the functions are in mondrian_drm.c, which carries a
 * request to the kernel's GPU user client (the service MondrianGPU;
 * iokit/Kernel/arm/MondrianGPU.cpp) as one IOConnectCallStructMethod whose
 * selector is the low byte of the ioctl code. tools/mk-mesa-ios.sh puts both
 * into Mesa's tree, at src/mondrian-drm, where they stand in for dep_libdrm.
 * The request numbers and their structures are Linux's, unmodified (Mesa's
 * include/drm-uapi/msm_drm.h).
 */
#ifndef MONDIAN_XF86DRM_H
#define MONDIAN_XF86DRM_H

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "drm-uapi/drm.h"

#define DRM_NODE_PRIMARY	0
#define DRM_NODE_RENDER		2
#define DRM_CLOEXEC		O_CLOEXEC
#define DRM_RDWR		O_RDWR

typedef struct _drmVersion {
	int version_major, version_minor, version_patchlevel;
	int name_len;
	char *name;
	int date_len;
	char *date;
	int desc_len;
	char *desc;
} drmVersion, *drmVersionPtr;

int drmOpenWithType(const char *name, const char *busid, int type);
int drmIoctl(int fd, unsigned long request, void *arg);
int drmCommandWrite(int fd, unsigned long index, const void *data,
    unsigned long size);
int drmCommandWriteRead(int fd, unsigned long index, void *data,
    unsigned long size);
drmVersionPtr drmGetVersion(int fd);
void drmFreeVersion(drmVersionPtr version);
int drmGetCap(int fd, uint64_t capability, uint64_t *value);

/*
 * Buffers and fences as file descriptors: there are none here, so these
 * return ENOSYS. A buffer is made by DRM_MSM_GEM_NEW and unmade by
 * DRM_IOCTL_GEM_CLOSE; nothing in this port shares one with another process.
 * The IOSurface request (0x7e) that would put a surface's memory here in place
 * of a prime file descriptor is not in the kernel yet; mondrian_drm.c marks
 * where it goes.
 */
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd);
int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle);
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle);
int drmSyncobjDestroy(int fd, uint32_t handle);
int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t count);
int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle);
int drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd);
int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd);
int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd);

/*
 * Not libdrm's: a buffer's memory in this process, in place of mmap() on the
 * device. freedreno's Darwin back end calls these (src/freedreno/drm is
 * patched to), and the kernel maps the memory of the buffer whose number is
 * its GEM handle. mondrian_drm_map()'s MAP_FAILED is (void *)-1.
 */
void *mondrian_drm_map(int fd, uint32_t handle, uint64_t size);
void mondrian_drm_unmap(int fd, uint32_t handle, void *address);

#endif /* MONDIAN_XF86DRM_H */
