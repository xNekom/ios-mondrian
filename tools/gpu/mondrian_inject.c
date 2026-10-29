/*
 * /usr/libexec/mondrian-inject.dylib: the library that puts CoreAnimation's OpenGL ES renderer
 * on the Adreno 730.
 *
 * WHO LOADS IT AND WHERE
 *
 *   launchd -> /usr/libexec/backboardd
 *     + DYLD_INSERT_LIBRARIES=/usr/libexec/mondrian-ui-hook.dylib   (kernel patch 0112,
 *       boot-arg mondrian_ui_hook=2, tools/mondrian-ui-hook.m)
 *       + that dylib's constructor dlopen()s this file (see docs/COREANIMATION_GLES.md for the one
 *         line that points it here; today it loads the GPU smoke test from the same function)
 *           + this constructor: wait for MondrianGPU, dlopen(MONDIAN_GL_LIBRARY), hook
 *
 * Everything therefore runs inside backboardd, which is where the window server draws. This file
 * changes nothing outside its own address space.
 *
 * WHAT IT DOES
 *
 *   1. (glslots=1 only) prints the function table iOS's own OpenGL ES builds -- offsets and
 *      names -- and returns without hooking anything. That dump is what completes
 *      tools/gpu/eagl_slots.txt for this userland: see docs/COREANIMATION_GLES.md.
 *   2. Otherwise: waits for the kernel's GPU service (MondrianGPU, xnu patch 0182), loads
 *      /usr/libexec/mondrian-gl.dylib (eagl.c + gl_osmesa.c + Mesa behind them) and replaces two
 *      entries of CA::OGL::GLESContext's vtable:
 *
 *        function_supported()  -- which of its ninety shader "functions" the renderer has; the
 *                                 ones it says no to are ones our library draws with programs of
 *                                 its own (eagl.c), and it has to be told.
 *        function_uniform()    -- the numbers those functions are given (a colour matrix, ...),
 *                                 which eagl.c keeps (mondrian_gl_function_values()).
 *
 *      Without the second hook the lock screen's vibrantColorMatrix layer is a red veil; without
 *      the first, the layer is not drawn at all.
 *
 * Addresses and slots are in tools/gpu/mondrian_offsets.h and are properties of the iOS build
 * (iPhone X 16.7.16, 20H392). Each replacement checks that the slot still holds the function it
 * expects and leaves the vtable alone when it does not, printing what it found: a wrong number is
 * a missing feature, not a crash.
 *
 * NOT YET RUN ON HARDWARE. It compiles for iOS 16 arm64. The scheme is the one a working Adreno
 * 610 port of the same userland uses; the service name, the library path and the numbers differ.
 * The container-manager (personas) workaround that port's injector also carried lives in
 * tools/mondrian-ui-hook.m on this port and is not repeated here: this file is only the GPU.
 *
 * Log lines go to stderr (which launchd sends to /dev/null) and to /dev/console, which on this
 * port is the kernel's log ring: tools/mondrian-boot-log.sh and the console photo show them.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <syslog.h>
#include <unistd.h>

#include "mondrian_offsets.h"

#define GPU_SERVICE     "MondrianGPU"

extern const void *_dyld_get_shared_cache_range(size_t *length);

static int console_fd = -1;

static void
say(const char *format, ...)
{
	char line[900];
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if (n > (int)sizeof(line) - 1) {
		n = (int)sizeof(line) - 1;
	}
	(void)write(STDERR_FILENO, line, (size_t)n);
	if (console_fd >= 0) {
		(void)write(console_fd, line, (size_t)n);
	}
}

/* Is this word in the kernel's boot-args? The whole word, not a prefix of a longer one. */
static int
has_boot_argument(const char *argument)
{
	char arguments[1024] = "";
	size_t length = sizeof(arguments) - 1;
	const char *found;
	size_t used = strlen(argument);

	if (sysctlbyname("kern.bootargs", arguments, &length, NULL, 0) != 0) {
		return 0;
	}
	for (found = strstr(arguments, argument); found != NULL; found = strstr(found + 1, argument)) {
		if ((found == arguments || found[-1] == ' ') &&
		    (found[used] == 0 || found[used] == ' ')) {
			return 1;
		}
	}
	return 0;
}

/* ---- the table iOS's own OpenGL ES hands CoreAnimation (glslots=1) ------------------------- */

/*
 * The offsets in mondrian_offsets.h and eagl_slots.txt were taken from this table. Asking the
 * build itself is the only way to be sure of it: -getMacroContextPrivate returns an array of
 * function pointers, every one of them in OpenGLES, and the cache keeps their names -- the
 * offset of an entry divided by 8 is the index CoreAnimation uses.
 *
 * iOS's context is made here with iOS's own -initWithAPI:properties: (nothing has been replaced
 * yet: the GL library is not loaded in this mode). If it cannot be made -- no GPU behind Apple's
 * GLES -- the dump is empty and the log says so.
 */
static void
dump_slots(void)
{
	Class context_class = objc_getClass("EAGLContext");
	id (*alloc_object)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
	id (*init_context)(id, SEL, unsigned long, id) = (id (*)(id, SEL, unsigned long, id))objc_msgSend;
	void *(*get_table)(id, SEL) = (void *(*)(id, SEL))objc_msgSend;
	id object;
	void **table;
	unsigned named = 0, empty = 0;

	if (context_class == Nil) {
		say("mondrian-gl: glslots: this program has no EAGLContext\n");
		return;
	}
	object = alloc_object((id)context_class, sel_registerName("alloc"));
	object = init_context(object, sel_registerName("initWithAPI:properties:"), 3, nil);
	if (object == nil) {
		say("mondrian-gl: glslots: no context of API 3 from iOS's GLES: nothing to dump\n");
		return;
	}
	table = get_table(object, sel_registerName("getMacroContextPrivate"));
	if (table == NULL) {
		say("mondrian-gl: glslots: -getMacroContextPrivate is NULL\n");
		return;
	}
	for (unsigned slot = 1; slot < MONDIAN_GL_TABLE_SLOTS; slot++) {
		Dl_info info;

		if (table[slot] == NULL) {
			/* the table is shorter than the space eagl.c keeps for it: stop at its end */
			if (++empty > 32) {
				break;
			}
			continue;
		}
		empty = 0;
		if (dladdr(table[slot], &info) && info.dli_sname != NULL && info.dli_sname[0] == 'g') {
			say("mondrian-gl: slot %#06x %s\n", slot * 8, info.dli_sname);
			named++;
		} else {
			say("mondrian-gl: slot %#06x (not named)\n", slot * 8);
		}
	}
	say("mondrian-gl: glslots: %u entries named; tools/gpu/mkeagl.py --from-log completes "
	    "eagl_slots.txt\n", named);
}

/* ---- replacing a vtable entry -------------------------------------------------------------- */

static uintptr_t slide;

static void *
replace_virtual(const char *what, uintptr_t slot, uintptr_t expected, void *replacement)
{
	uintptr_t *entry = (uintptr_t *)(slot + slide);
	vm_address_t page = (vm_address_t)entry & ~(vm_address_t)(vm_page_size - 1);
	void *original;

	if (*entry != expected + slide) {
		say("mondrian-gl: %s: slot holds %#lx, expected %#lx: left alone\n", what, *entry - slide,
		    (unsigned long)expected);
		return NULL;
	}
	if (vm_protect(mach_task_self(), page, vm_page_size, FALSE,
	    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
		say("mondrian-gl: %s: table not writable\n", what);
		return NULL;
	}
	original = (void *)*entry;
	*entry = (uintptr_t)replacement;
	(void)vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ);
	return original;
}

/*
 * The "function" the context is drawing with lives at a fixed place inside it: see
 * mondrian_offsets.h, where both offsets are named.
 */
static unsigned
context_function(void *context)
{
	void *state = *(void **)((char *)context + MONDIAN_CA_CONTEXT_STATE);

	return state != NULL ? *(unsigned *)((char *)state + MONDIAN_CA_FUNCTION_FIELD) : 0;
}

static int (*orig_function_supported)(void *context);
static void (*orig_function_uniform)(void *context, unsigned index, size_t components, size_t count,
    const float *values);
static void (*gl_function_refused)(unsigned function);
static void (*gl_function_values)(void *context, unsigned function, unsigned index, size_t components,
    size_t count, const float *values);

static int
my_function_supported(void *context)
{
	static uint8_t said[256];
	int supported = orig_function_supported(context);
	unsigned function = context_function(context);

	if (!supported) {
		if (gl_function_refused != NULL) {
			gl_function_refused(function);
		}
		if (!said[function & 255]) {
			said[function & 255] = 1;
			say("mondrian-gl: CoreAnimation's GL renderer has no function %u\n", function);
		}
	}
	return supported;
}

static void
my_function_uniform(void *context, unsigned index, size_t components, size_t count, const float *values)
{
	gl_function_values(context, context_function(context), index, components, count, values);
	orig_function_uniform(context, index, components, count, values);
}

static void
gl_hooks(void *library)
{
	size_t length = 0;
	const void *cache = _dyld_get_shared_cache_range(&length);

	if (cache == NULL || library == NULL) {
		say("mondrian-gl: no shared cache or no library: nothing hooked\n");
		return;
	}
	slide = (uintptr_t)cache - MONDIAN_CACHE_BASE;
	gl_function_refused = (void (*)(unsigned))dlsym(library, "mondrian_gl_function_refused");
	gl_function_values = (void (*)(void *, unsigned, unsigned, size_t, size_t, const float *))dlsym(library,
	    "mondrian_gl_function_values");
	orig_function_supported = replace_virtual("function_supported",
	    MONDIAN_CA_GLESCONTEXT_VTABLE + 0x10 + MONDIAN_CA_VSLOT_FUNCTION_SUPPORTED,
	    MONDIAN_CA_FN_FUNCTION_SUPPORTED, my_function_supported);
	if (gl_function_values != NULL) {
		orig_function_uniform = replace_virtual("function_uniform",
		    MONDIAN_CA_GLESCONTEXT_VTABLE + 0x10 + MONDIAN_CA_VSLOT_FUNCTION_UNIFORM,
		    MONDIAN_CA_FN_FUNCTION_UNIFORM, my_function_uniform);
	}
	say("mondrian-gl: GLESContext hooks: function_supported %s, function_uniform %s\n",
	    orig_function_supported ? "on" : "OFF", orig_function_uniform ? "on" : "OFF");
}

/* ---- where a crash happened, in the console ------------------------------------------------- */

static void
where(const char *what, void *address)
{
	Dl_info info;

	if (dladdr(address, &info) && info.dli_fname != NULL) {
		say("mondrian-crash: %s %p = %s+0x%lx (%s)\n", what, address, info.dli_fname,
		    (unsigned long)((char *)address - (char *)info.dli_fbase), info.dli_sname ? info.dli_sname : "?");
	} else {
		say("mondrian-crash: %s %p (no image)\n", what, address);
	}
}

static void
crash(int signal_number, siginfo_t *info, void *context)
{
	ucontext_t *state = (ucontext_t *)context;
	void *frames[16];
	int count;

	say("mondrian-crash: signal %d at address %p\n", signal_number, info ? info->si_addr : NULL);
	if (state != NULL && state->uc_mcontext != NULL) {
		where("pc", (void *)state->uc_mcontext->__ss.__pc);
		where("lr", (void *)state->uc_mcontext->__ss.__lr);
	}
	count = backtrace(frames, 16);
	for (int i = 0; i < count; i++) {
		where("bt", frames[i]);
	}
	signal(signal_number, SIG_DFL);
	raise(signal_number);
}

static void
crash_handlers(void)
{
	struct sigaction action;
	int signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };

	memset(&action, 0, sizeof(action));
	action.sa_sigaction = crash;
	action.sa_flags = SA_SIGINFO;
	for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		(void)sigaction(signals[i], &action, NULL);
	}
}

__attribute__((constructor)) static void
mondrian_inject(void)
{
	const char *name = getprogname();
	io_service_t gpu;
	void *library;

	console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (name == NULL || strcmp(name, "backboardd") != 0) {
		return;
	}
	if (has_boot_argument("glslots=1")) {
		dump_slots();
		return;
	}
	if (access(MONDIAN_GL_LIBRARY, R_OK) != 0) {
		say("mondrian-gl: no %s: the window server keeps its renderer\n", MONDIAN_GL_LIBRARY);
		return;
	}
	/* the kernel publishes the service once the root filesystem is there: give it a moment */
	for (int i = 0; i < 50; i++) {
		gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(GPU_SERVICE));
		if (gpu != 0) {
			break;
		}
		usleep(100000);
	}
	if (gpu == 0) {
		say("mondrian-gl: no %s: the window server keeps its renderer\n", GPU_SERVICE);
		return;
	}
	IOObjectRelease(gpu);
	crash_handlers();
	library = dlopen(MONDIAN_GL_LIBRARY, RTLD_NOW);
	gl_hooks(library);
	say("mondrian-crash: handlers set, GL %s\n", library != NULL ? "loaded" : dlerror());
	syslog(LOG_NOTICE, "mondrian: %s %s", MONDIAN_GL_LIBRARY, library != NULL ? "loaded" : dlerror());
}
