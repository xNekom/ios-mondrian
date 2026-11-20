/*
 * Injected into MobileSafari at exec by 0393.
 *
 * WebKit on iOS draws page content in the GPU process by default ("GPU
 * Process: DOM Rendering"). On this port that process creates and locks its
 * surface and then never reaches a single drawing entry point (measured
 * 2026-11-19: Metal's factory, CGBitmapContextCreate, CGContextFillRect,
 * CGContextDrawImage, glClear, glDrawArrays, glTexImage2D), so the page stays
 * black while Safari's own chrome draws.
 *
 * The feature is an experimental flag, and WebKit reads the override from the
 * application's own defaults under `WebKitExperimental<Feature key>`
 * (Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm). With
 * it off, the WebContent process paints the layers itself into a mappable
 * IOSurface, which is the path this port already serves: bug 247483 describes
 * the same black page on iOS 16 fixed by turning the flag off in Safari's
 * settings.
 *
 * The value has to be in place before WebKit reads it, and a constructor runs
 * before main, so this is the one place that costs no launchd edit.
 */
#import <Foundation/Foundation.h>

#import <stdio.h>
#import <string.h>
#import <unistd.h>

#define PREF  "WebKitExperimentalUseGPUProcessForDOMRenderingEnabled"
#define LOG   "/private/var/mobile/Library/Preferences/mondrian-safari.log"

static void
safari_log(const char *line)
{
	FILE *f = fopen(LOG, "a");

	if (f != NULL) {
		fputs(line, f);
		fclose(f);
	}
}

__attribute__((constructor))
static void
mondrian_safari_init(void)
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	char line[256];

	[defaults setBool:NO forKey:@PREF];
	[defaults synchronize];

	snprintf(line, sizeof(line),
	    "mondrian-safari[%d]: %s now %d\n", getpid(), PREF,
	    [defaults boolForKey:@PREF] ? 1 : 0);
	safari_log(line);
}
