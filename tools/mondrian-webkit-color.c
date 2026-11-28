/*
 * Injected into WebKit's GPU process by patch 0385 (alongside the Metal
 * provider). vphone-cli issue #756: WebKit asks MobileGestalt for
 * HasExtendedColorDisplay and, when the answer is yes, requests w30r (10-bit)
 * IOSurfaces. This port's HAL only serves BGRA, so the surfaces stay zero and
 * Safari's page content is black. Forcing the answer false makes WebCore pick
 * 8-bit backing stores and the page paints.
 *
 * dyld interposing is used rather than a constructor setting a preference:
 * the GPU process is a separate exec, and MobileSafari's own defaults do not
 * reach it. CoreFoundation only: a Foundation call at constructor time has
 * already been measured to abort a WebKit client on this port.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <syslog.h>

extern Boolean MGGetBoolAnswer(CFStringRef) __attribute__((weak_import));
extern CFTypeRef MGCopyAnswer(CFStringRef) __attribute__((weak_import));

struct mondrian_interpose {
	const void *replacement;
	const void *replacee;
};

static const struct mondrian_interpose color_bool_interpose;
static const struct mondrian_interpose color_copy_interpose;

static int
is_key(CFStringRef key, const char *want)
{
	char buf[128];

	if (key == NULL ||
	    !CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8))
		return 0;
	return strcmp(buf, want) == 0;
}

static Boolean
mondrian_color_bool(CFStringRef key)
{
	Boolean (*real)(CFStringRef) =
	    (Boolean (*)(CFStringRef))color_bool_interpose.replacee;

	if (is_key(key, "HasExtendedColorDisplay")) {
		syslog(5, "MONDRIAN COLOR: HasExtendedColorDisplay -> false");
		return false;
	}
	return real != NULL ? real(key) : false;
}

static CFTypeRef
mondrian_color_copy(CFStringRef key)
{
	CFTypeRef (*real)(CFStringRef) =
	    (CFTypeRef (*)(CFStringRef))color_copy_interpose.replacee;

	if (is_key(key, "HasExtendedColorDisplay") ||
	    is_key(key, "artwork-display-gamut")) {
		syslog(5, "MONDRIAN COLOR: extended gamut query -> false");
		return kCFBooleanFalse;
	}
	return real != NULL ? real(key) : NULL;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose color_bool_interpose = {
	(const void *)mondrian_color_bool,
	(const void *)MGGetBoolAnswer,
};

__attribute__((used, section("__DATA,__interpose")))
static const struct mondrian_interpose color_copy_interpose = {
	(const void *)mondrian_color_copy,
	(const void *)MGCopyAnswer,
};
