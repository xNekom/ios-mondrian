/* <copyfile.h> for xnu's SETUP/installfile on Linux.
 *
 * installfile() is what the whole install step uses to copy a file with a
 * mode, and it calls fcopyfile(3). Darwin's version also copies ACLs and
 * xattrs; the Linux build only needs the data and the mode, which installfile
 * applies itself with fchmod(). Implemented in hostcompat.c.
 */
#ifndef XNU_LINUX_COPYFILE_H
#define XNU_LINUX_COPYFILE_H

#include <sys/types.h>

typedef struct xnu_copyfile_state *copyfile_state_t;

#define COPYFILE_ACL       (1 << 0)
#define COPYFILE_STAT      (1 << 1)
#define COPYFILE_XATTR     (1 << 2)
#define COPYFILE_DATA      (1 << 3)
#define COPYFILE_SECURITY  (COPYFILE_STAT | COPYFILE_ACL)
#define COPYFILE_METADATA  (COPYFILE_SECURITY | COPYFILE_XATTR)
#define COPYFILE_ALL       (COPYFILE_METADATA | COPYFILE_DATA)

copyfile_state_t copyfile_state_alloc(void);
void copyfile_state_free(copyfile_state_t state);
int fcopyfile(int from_fd, int to_fd, copyfile_state_t state, int flags);
int copyfile(const char *from, const char *to, copyfile_state_t state, int flags);

#endif /* XNU_LINUX_COPYFILE_H */
