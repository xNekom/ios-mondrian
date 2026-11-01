/* <mach/mach_init.h> for xnu's SETUP/kextsymboltool on Linux.
 *
 * The tool pulls exactly one thing from it, mach_vm_round_page(), to find the
 * symbol table that follows the load commands of a kext's Mach-O file. The
 * 4 KiB page is the Mach-O file-layout constant on the Intel Macs this tool
 * was written for; nothing in a mondrian build calls it (the kernel is
 * monolithic and no kext links here), it only has to exist.
 */
#ifndef XNU_LINUX_MACH_INIT_H
#define XNU_LINUX_MACH_INIT_H

#include <stdint.h>

typedef uint64_t mach_vm_offset_t;
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;

#define XNU_LINUX_MACH_VM_PAGE_MASK 0xfffULL

static inline mach_vm_offset_t
mach_vm_round_page(mach_vm_offset_t x)
{
	return (x + XNU_LINUX_MACH_VM_PAGE_MASK) & ~XNU_LINUX_MACH_VM_PAGE_MASK;
}

static inline mach_vm_offset_t
mach_vm_trunc_page(mach_vm_offset_t x)
{
	return x & ~XNU_LINUX_MACH_VM_PAGE_MASK;
}

#endif /* XNU_LINUX_MACH_INIT_H */
