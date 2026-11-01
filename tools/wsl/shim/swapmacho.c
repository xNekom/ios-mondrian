/* mach-o/swap.h implementations for the Linux XNU build.
 *
 * On macOS these live in libSystem and only the SETUP tools use them: they
 * convert the fields of a Mach-O structure read from a file to host order.
 * cctools-port ships the header but no implementation, and kextsymboltool
 * references eight of them at link time. Only the eight are here; add more
 * when a tool actually needs one, rather than shipping the whole surface
 * untested.
 */
#include <stdint.h>

#include <architecture/byte_order.h>
#include <mach-o/arch.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/swap.h>

/* libSystem's libmacho provides this; kextsymboltool asks for the host's
 * byte order and cpu type. The build host is always x86_64 or arm64 Linux,
 * i.e. little-endian, which is the only field the tool acts on. */
static const NXArchInfo xnu_linux_local_arch = {
#if defined(__aarch64__)
	"arm64",
	CPU_TYPE_ARM64,
	CPU_SUBTYPE_ARM64_ALL,
#else
	"x86_64",
	CPU_TYPE_X86_64,
	CPU_SUBTYPE_X86_64_ALL,
#endif
	NX_LittleEndian,
	"Linux host"
};

const NXArchInfo *
NXGetLocalArchInfo(void)
{
	return &xnu_linux_local_arch;
}

static int
need_swap(enum NXByteOrder order)
{
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
	return order == NX_LittleEndian;
#else
	return order == NX_BigEndian;
#endif
}

#define SW32(field) (field = __builtin_bswap32((uint32_t)(field)))
#define SW64(field) (field = __builtin_bswap64((uint64_t)(field)))
#define SW16(field) (field = (uint16_t)__builtin_bswap16((uint16_t)(field)))

void
swap_mach_header(struct mach_header *mh, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(mh->magic);
	SW32(mh->cputype);
	SW32(mh->cpusubtype);
	SW32(mh->filetype);
	SW32(mh->ncmds);
	SW32(mh->sizeofcmds);
	SW32(mh->flags);
}

void
swap_mach_header_64(struct mach_header_64 *mh, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(mh->magic);
	SW32(mh->cputype);
	SW32(mh->cpusubtype);
	SW32(mh->filetype);
	SW32(mh->ncmds);
	SW32(mh->sizeofcmds);
	SW32(mh->flags);
	SW32(mh->reserved);
}

void
swap_segment_command(struct segment_command *sg, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(sg->cmd);
	SW32(sg->cmdsize);
	SW32(sg->vmaddr);
	SW32(sg->vmsize);
	SW32(sg->fileoff);
	SW32(sg->filesize);
	SW32(sg->maxprot);
	SW32(sg->initprot);
	SW32(sg->nsects);
	SW32(sg->flags);
}

void
swap_segment_command_64(struct segment_command_64 *sg, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(sg->cmd);
	SW32(sg->cmdsize);
	SW64(sg->vmaddr);
	SW64(sg->vmsize);
	SW64(sg->fileoff);
	SW64(sg->filesize);
	SW32(sg->maxprot);
	SW32(sg->initprot);
	SW32(sg->nsects);
	SW32(sg->flags);
}

void
swap_symtab_command(struct symtab_command *st, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(st->cmd);
	SW32(st->cmdsize);
	SW32(st->symoff);
	SW32(st->nsyms);
	SW32(st->stroff);
	SW32(st->strsize);
}

void
swap_uuid_command(struct uuid_command *uuid_cmd, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	SW32(uuid_cmd->cmd);
	SW32(uuid_cmd->cmdsize);
	/* the 16 uuid bytes are byte-order agnostic */
}

void
swap_nlist(struct nlist *symbols, uint32_t nsymbols, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	for (uint32_t i = 0; i < nsymbols; i++) {
		SW32(symbols[i].n_un.n_strx);
		SW16(symbols[i].n_desc);
		SW32(symbols[i].n_value);
	}
}

void
swap_nlist_64(struct nlist_64 *symbols, uint32_t nsymbols, enum NXByteOrder order)
{
	if (!need_swap(order)) {
		return;
	}
	for (uint32_t i = 0; i < nsymbols; i++) {
		SW32(symbols[i].n_un.n_strx);
		SW16(symbols[i].n_desc);
		SW64(symbols[i].n_value);
	}
}
