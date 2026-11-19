/*
 * A load probe with no logging in it: if dyld inserts this dylib into a
 * process, the constructor aborts that process. Silence means dyld refused the
 * insertion, and no ring channel can lie about it.
 */
#include <stdlib.h>

__attribute__((constructor)) static void
mondrian_load_probe(void)
{
	abort();
}
