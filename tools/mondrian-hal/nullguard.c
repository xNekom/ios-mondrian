/*
 * MondrianNullGuard.dylib - injected into mediaserverd by patch 0511.
 *
 * CoreAudio's HALS_System::DeviceManagerCreated passes a NULL C string to a
 * CoreFoundation routine; the fault is `ldr x8, [x0]` at
 * CoreFoundation __TEXT + 0x7ab64 with x0 == 0, killing mediaserverd.
 * Replace that single instruction with `mov x8, #0` so the following
 * compares (cmp x8,#0 / ccmp x8,x9,#4,ne) take the benign path.
 *
 * All addresses are found at runtime from the Mach-O header + slide, so
 * no hardcoded cache offsets are needed beyond the function-relative one.
 */
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <mach/vm_param.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>

#define CF_TEXT_OFFSET  0x7ab64u   /* faulting ldr x8,[x0] within CoreFoundation __TEXT */
#define MOV_X8_0        0x52800008u

extern const char *_dyld_get_image_name(uint32_t index);
extern uintptr_t _dyld_get_image_header(uint32_t index);
extern intptr_t _dyld_get_image_slide(uint32_t index);
extern uint32_t _dyld_image_count(void);

static bool
patch_corefoundation(void)
{
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const char *name = _dyld_get_image_name(i);
		if (name == NULL || strstr(name, "CoreFoundation.framework/CoreFoundation") == NULL)
			continue;
		uintptr_t base = _dyld_get_image_header(i);
		if (base == 0)
			continue;
		uintptr_t addr = base + CF_TEXT_OFFSET;
		uintptr_t page = addr & ~(uintptr_t)(vm_page_size - 1);
		FILE *f = fopen("/var/mobile/nullguard.log", "a");
		if (f != NULL) {
			uint32_t before = *(volatile uint32_t *)addr;
			fprintf(f, "nullguard: CF base %#lx target %#lx bytes %#x\n",
			    (unsigned long)base, (unsigned long)addr, before);
			fclose(f);
		}
		if (mprotect((void *)page, vm_page_size, PROT_READ | PROT_WRITE | PROT_EXEC) != 0)
			return false;
		volatile uint32_t *p = (volatile uint32_t *)addr;
		/* observed 0xf9400008 = ldr x8,[x0,#0x10]; patch any ldr x8,[x0,#imm]. */
		if (*p != MOV_X8_0) {
			*p = MOV_X8_0;
			__builtin___clear_cache((char *)p, (char *)(p + 1));
		}
		return true;
	}
	return false;
}

__attribute__((constructor)) static void
install(void)
{
	bool ok = patch_corefoundation();
	FILE *f = fopen("/var/mobile/nullguard.log", "a");
	if (f != NULL) {
		fprintf(f, "nullguard: CoreFoundation patch %s\n", ok ? "OK" : "FAILED");
		fclose(f);
	}
}
