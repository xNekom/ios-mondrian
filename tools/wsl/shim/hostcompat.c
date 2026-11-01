/* BSD calls xnu's SETUP host tools make that glibc does not provide.
 *
 * Built into libhostcompat.a by tools/wsl/bootstrap-toolchain.sh; host-clang
 * links it. Keep this list to what the tools actually call, so the Linux build
 * stays as close to the macOS one as possible.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/stat.h>
#include <sys/types.h>

#include "copyfile.h"

/* ------------------------------------------------------------ setmode/getmode */
/* The classic BSD mode editor. xnu's install rules pass octal modes ("0644"),
 * but a few Apple targets use the symbolic form ("u+w"), and a parser that only
 * understood octal would drop those bits silently. */
struct xnu_setmode {
	uint16_t mode;
	int who;                /* S_ISUID/... bits already named */
	int op;                 /* '+', '-' or '=' */
	int perm;               /* bits accumulated for this operator */
};

static mode_t
bits_for(int who, int perm)
{
	mode_t bits = 0;

	if (who & 1) {          /* user */
		bits |= (perm & 4) ? S_IRUSR : 0;
		bits |= (perm & 2) ? S_IWUSR : 0;
		bits |= (perm & 1) ? S_IXUSR : 0;
		bits |= (perm & 7) ? 0 : 0;
	}
	if (who & 2) {          /* group */
		bits |= (perm & 4) ? S_IRGRP : 0;
		bits |= (perm & 2) ? S_IWGRP : 0;
		bits |= (perm & 1) ? S_IXGRP : 0;
	}
	if (who & 4) {          /* other */
		bits |= (perm & 4) ? S_IROTH : 0;
		bits |= (perm & 2) ? S_IWOTH : 0;
		bits |= (perm & 1) ? S_IXOTH : 0;
	}
	return bits;
}

static void
apply(struct xnu_setmode *s)
{
	mode_t bits = bits_for(s->who, s->perm);

	switch (s->op) {
	case '+':
		s->mode |= bits;
		break;
	case '-':
		s->mode &= (uint16_t)~bits;
		break;
	case '=':
		/* "=" clears the category first */
		s->mode &= (uint16_t)~(bits_for(s->who, 7));
		s->mode |= bits;
		break;
	}
	s->op = 0;
	s->perm = 0;
	s->who = 0;
}

void *
setmode(const char *mode_string)
{
	struct xnu_setmode *s;

	if (mode_string == NULL) {
		errno = EINVAL;
		return NULL;
	}
	s = calloc(1, sizeof(*s));
	if (s == NULL) {
		return NULL;
	}

	if (*mode_string >= '0' && *mode_string <= '7') {
		char *end = NULL;
		unsigned long value = strtoul(mode_string, &end, 8);

		if (end == NULL || *end != '\0' || value > 07777) {
			free(s);
			errno = EINVAL;
			return NULL;
		}
		s->mode = (uint16_t)value;
		return s;
	}

	for (const char *p = mode_string; *p != '\0'; p++) {
		switch (*p) {
		case 'u': s->who |= 1; continue;
		case 'g': s->who |= 2; continue;
		case 'o': s->who |= 4; continue;
		case 'a': s->who |= 7; continue;
		case '+': case '-': case '=':
			s->op = *p;
			continue;
		case 'r': s->perm |= 4; continue;
		case 'w': s->perm |= 2; continue;
		case 'x': s->perm |= 1; continue;
		case 'X': s->perm |= 1; continue;
		case 's': s->perm |= 0; continue;       /* suid/sgid are not used */
		case ',': apply(s); continue;
		default:
			free(s);
			errno = EINVAL;
			return NULL;
		}
	}
	apply(s);
	return s;
}

mode_t
getmode(const void *set, mode_t mode)
{
	const struct xnu_setmode *s = set;

	if (s == NULL) {
		return mode;
	}
	/* the parsed bits are absolute; the incoming mode is only a base */
	return (mode & (mode_t)~07777) | s->mode;
}

/* ------------------------------------------------------------------ copyfile */
struct xnu_copyfile_state {
	int unused;
};

copyfile_state_t
copyfile_state_alloc(void)
{
	return calloc(1, sizeof(struct xnu_copyfile_state));
}

void
copyfile_state_free(copyfile_state_t state)
{
	free(state);
}

int
fcopyfile(int from_fd, int to_fd, copyfile_state_t state, int flags)
{
	char buf[65536];
	ssize_t n;

	(void)state;
	(void)flags;
	for (;;) {
		n = read(from_fd, buf, sizeof(buf));
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			return -1;
		}
		if (n == 0) {
			return 0;
		}
		for (ssize_t off = 0; off < n;) {
			ssize_t w = write(to_fd, buf + off, (size_t)(n - off));

			if (w < 0) {
				if (errno == EINTR) {
					continue;
				}
				return -1;
			}
			off += w;
		}
	}
}

int
copyfile(const char *from, const char *to, copyfile_state_t state, int flags)
{
	int in, out, ret;

	(void)state;
	(void)flags;
	in = open(from, O_RDONLY);
	if (in < 0) {
		return -1;
	}
	out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (out < 0) {
		close(in);
		return -1;
	}
	ret = fcopyfile(in, out, NULL, 0);
	close(in);
	if (close(out) < 0) {
		ret = -1;
	}
	return ret;
}
