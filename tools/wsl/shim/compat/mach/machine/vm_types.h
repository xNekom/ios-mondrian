/* <mach/machine/vm_types.h> for the SETUP host tools on Linux.
 *
 * cctools' <mach/machine.h> imports it, and Darwin resolves it to the SDK's
 * per-architecture directory. cctools ships the same file under include/foreign
 * but that whole tree shadows libc headers (its strings.h collides with
 * glibc's index/rindex), so only this one indirection is borrowed here.
 */
#ifndef XNU_LINUX_MACH_MACHINE_VM_TYPES_H
#define XNU_LINUX_MACH_MACHINE_VM_TYPES_H

#if defined(__x86_64__) || defined(__i386__)
#include <mach/i386/vm_types.h>
#elif defined(__aarch64__)
#include <mach/arm/vm_types.h>
#else
#error "unsupported Linux host architecture"
#endif

#endif /* XNU_LINUX_MACH_MACHINE_VM_TYPES_H */
