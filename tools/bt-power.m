/*
 * Ask bluetoothd to power the controller through the same private framework
 * SpringBoard uses. The Control Center button is inert while the daemon reports
 * no controller, but the framework call is the message the button would send.
 *
 * Run it from the UI hook: write its path into /private/var/vm/mondrian-run.
 * It prints to /dev/console, which is the ring.
 */
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void
list_methods(Class cls, const char *what)
{
	unsigned int count = 0;
	Method *methods;
	unsigned int i;

	if (cls == Nil) {
		printf("bt-power: %s nil\n", what);
		return;
	}
	methods = class_copyMethodList(cls, &count);
	printf("bt-power: %s %u methods\n", what, count);
	for (i = 0; i < count; i++) {
		const char *name = sel_getName(method_getName(methods[i]));

		if (strstr(name, "ower") != NULL ||
		    strstr(name, "Power") != NULL ||
		    strstr(name, "shared") != NULL) {
			printf("bt-power:   %s\n", name);
		}
	}
	free(methods);
}

int
main(void)
{
	void *lib;
	Class cls;
	id instance;
	SEL shared, powered_sel, set_powered, power_state, set_state;
	BOOL (*powered)(id, SEL);
	void (*set_powered_fn)(id, SEL, BOOL);
	int (*power_state_fn)(id, SEL);
	void (*set_state_fn)(id, SEL, int);
	int before = -1;

	printf("bt-power: start uid %d\n", getuid());
	lib = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/"
	    "BluetoothManager", RTLD_NOW | RTLD_GLOBAL);
	printf("bt-power: dlopen %p %s\n", lib, lib != NULL ? "ok" : dlerror());
	cls = objc_getClass("BluetoothManager");
	printf("bt-power: class %p\n", cls);
	if (cls == Nil) {
		return 1;
	}
	list_methods(cls, "class");
	list_methods(object_getClass((id)cls), "meta");

	shared = sel_registerName("sharedInstance");
	instance = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
	printf("bt-power: instance %p\n", instance);
	if (instance == Nil) {
		return 1;
	}
	list_methods(object_getClass(instance), "instance");
	list_methods(object_getClass(instance), "instance-meta");

	powered_sel = sel_registerName("powered");
	if ([(id)instance respondsToSelector:powered_sel]) {
		powered = (BOOL (*)(id, SEL))objc_msgSend;
		before = powered(instance, powered_sel) ? 1 : 0;
		printf("bt-power: powered before %d\n", before);
	}
	power_state = sel_registerName("powerState");
	if ([(id)instance respondsToSelector:power_state]) {
		power_state_fn = (int (*)(id, SEL))objc_msgSend;
		printf("bt-power: powerState before %d\n",
		    power_state_fn(instance, power_state));
	}
	set_powered = sel_registerName("setPowered:");
	if ([(id)instance respondsToSelector:set_powered]) {
		set_powered_fn = (void (*)(id, SEL, BOOL))objc_msgSend;
		printf("bt-power: calling setPowered:YES\n");
		set_powered_fn(instance, set_powered, YES);
	} else {
		printf("bt-power: no setPowered:\n");
	}
	set_state = sel_registerName("setPowerState:");
	if ([(id)instance respondsToSelector:set_state]) {
		set_state_fn = (void (*)(id, SEL, int))objc_msgSend;
		printf("bt-power: calling setPowerState:5\n");
		set_state_fn(instance, set_state, 5);
	} else {
		printf("bt-power: no setPowerState:\n");
	}
	sleep(2);
	if ([(id)instance respondsToSelector:powered_sel]) {
		powered = (BOOL (*)(id, SEL))objc_msgSend;
		printf("bt-power: powered after %d\n",
		    powered(instance, powered_sel) ? 1 : 0);
	}
	printf("bt-power: done\n");
	return 0;
}
