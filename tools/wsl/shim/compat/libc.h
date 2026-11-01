/* <libc.h> for xnu's SETUP host tools on Linux.
 *
 * Darwin's libc.h is a grab bag of the BSD declarations the tools rely on
 * (getopt, err/errx, malloc, ...). glibc spreads the same names over the
 * standard headers and this file pulls them in, plus the two calls Darwin
 * puts here and glibc does not have at all: setmode(3) and getmode(3)
 * (implemented in hostcompat.c, force-included by host-clang).
 */
#ifndef XNU_LINUX_LIBC_H
#define XNU_LINUX_LIBC_H

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <err.h>

#include <sys/types.h>
#include <sys/stat.h>

void *setmode(const char *mode_string);
mode_t getmode(const void *set, mode_t mode);

#endif /* XNU_LINUX_LIBC_H */
