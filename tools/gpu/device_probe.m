/*
 * Does WebKit's GPU process ask for a Metal device at all? This interposes the
 * factory and aborts there: a dead process means the call happened, and no
 * other channel is needed to read the answer (the GPU process cannot log from
 * its sandbox). 50 KB instead of the 22 MB provider.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>

static id
mondrian_device_probe(void)
{
	abort();
	return nil;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
	const void *replacement;
	const void *replaced;
} mondrian_device_interpose[] = {
	{ (const void *)mondrian_device_probe, (const void *)MTLCreateSystemDefaultDevice },
};
