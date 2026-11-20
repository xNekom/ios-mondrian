/*
 * Injected into MobileSafari at exec by 0393.
 *
 * WebKit on iOS draws page content in the GPU process by default ("GPU
 * Process: DOM Rendering"). On this port that process creates and locks its
 * surface and then never reaches a single drawing entry point (measured
 * 2026-11-19), so the page stays black while Safari's chrome draws.
 *
 * The feature is an experimental flag, and WebKit reads the override from the
 * application's own defaults under `WebKitExperimental<Feature key>`
 * (Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm). With it
 * off, the WebContent process paints the layers itself into a mappable
 * IOSurface, the path this port serves: WebKit bug 247483 reports the same
 * black page on iOS 16 fixed by turning the flag off in Safari's settings.
 *
 * CFPreferences, not NSUserDefaults: measured 2026-11-20, a constructor that
 * asked Foundation for `standardUserDefaults` crashed MobileSafari on every
 * launch (sig 11 with `far` at the end of the stack, four corpses) while the
 * same launch without the dylib survived. CoreFoundation is what is safe this
 * early, and the app domain is the same store NSUserDefaults reads.
 */
#import <CoreFoundation/CoreFoundation.h>

#import <stdio.h>
#import <unistd.h>

#define PREF  "WebKitExperimentalUseGPUProcessForDOMRenderingEnabled"

__attribute__((constructor))
static void
mondrian_safari_init(void)
{
	CFStringRef key = CFSTR(PREF);
	Boolean value = false;

	CFPreferencesSetAppValue(key, kCFBooleanFalse, kCFPreferencesCurrentApplication);
	CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
	(void)value;
}
