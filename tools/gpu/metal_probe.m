/*
 * Does a dylib loaded at run time change MTLCreateSystemDefaultDevice? Prints
 * the device before and after dlopen of the provider. This settles the
 * mechanism before it is wired into WebKit's GPU process, whose surfaces stay
 * zero because it renders through Metal (0379/0380).
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

static const char *
named(id device)
{
	return device != nil ? [[device name] UTF8String] : "nil";
}

int
main(void)
{
	@autoreleasepool {
		void *handle;
		id after;

		setvbuf(stdout, NULL, _IONBF, 0);
		printf("metal_probe: %s, before: %s\n", getprogname(),
		    named(MTLCreateSystemDefaultDevice()));
		handle = dlopen("/private/var/vm/libmondrianmetal.dylib", RTLD_NOW);
		if (handle == NULL) {
			printf("metal_probe: dlopen failed: %s\n", dlerror());
			return 1;
		}
		after = MTLCreateSystemDefaultDevice();
		printf("metal_probe: after: %s\n", named(after));
		printf("metal_probe: %s\n", after != nil ? "PASS" : "FAIL");
		return after != nil ? 0 : 1;
	}
}
