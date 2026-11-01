/* macOS libc pieces xnu's SETUP host tools use and glibc does not have.
 *
 * tools/wsl/shim/host-clang force-includes this header (-include) for every
 * host tool it compiles, so the sources stay untouched. Keep it to what the
 * tools actually call: growing it to "all of BSD libc" is how a build starts
 * behaving differently from the macOS one.
 */
#ifndef XNU_LINUX_HOSTCOMPAT_H
#define XNU_LINUX_HOSTCOMPAT_H

/* program_invocation_short_name (glibc) needs this before <errno.h> */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <stddef.h>
#include <string.h>

#include <sys/types.h>

/* getprogname(3) is BSD libc; glibc keeps the same string in errno.h */
static inline const char *
xnu_host_getprogname(void)
{
	return program_invocation_short_name;
}
#define getprogname() xnu_host_getprogname()

/* setmode/getmode(3) are BSD; implemented in hostcompat.c (libhostcompat).
 * installfile.c uses them without including <libc.h>, which is where Darwin
 * declares them. */
void *setmode(const char *mode_string);
mode_t getmode(const void *set, mode_t mode);

/* strlcpy/strlcat arrived in glibc 2.38 */
#if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 38))
static inline size_t
strlcpy(char *dst, const char *src, size_t size)
{
	size_t len = strlen(src);

	if (size != 0) {
		size_t n = len < size - 1 ? len : size - 1;
		memcpy(dst, src, n);
		dst[n] = '\0';
	}
	return len;
}

static inline size_t
strlcat(char *dst, const char *src, size_t size)
{
	size_t dlen = strnlen(dst, size);

	if (dlen == size) {
		return size + strlen(src);
	}
	return dlen + strlcpy(dst + dlen, src, size - dlen);
}
#endif

#endif /* XNU_LINUX_HOSTCOMPAT_H */
