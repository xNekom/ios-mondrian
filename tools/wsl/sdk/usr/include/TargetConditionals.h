/* TargetConditionals.h for a Linux XNU build.
 *
 * xnu includes <TargetConditionals.h> from osfmk/mach/message.h, kern/debug.h,
 * OSMetaClass.h and friends, and on a Mac that file comes out of the macOS SDK.
 * There is no SDK here, so this file supplies the same TARGET_OS_/TARGET_CPU_
 * answers the macOS 13.5 kernel build gets. The values are not a guess about
 * the phone: the kernel is compiled with -DXNU_TARGET_OS_OSX and PLATFORM=MacOSX
 * exactly like the CI kernel, and 938 uses of TARGET_OS_OSX mean a missing
 * definition would silently select the wrong branch (an undefined macro is 0 in
 * #if, no diagnostic).
 *
 * Editing this file changes which code the kernel contains; keep it in step
 * with the macOS build, not with the target device.
 */
#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__

#define TARGET_OS_MAC 1
#define TARGET_OS_OSX 1
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_WATCH 0
#define TARGET_OS_TV 0
#define TARGET_OS_BRIDGE 0
#define TARGET_OS_VISION 0
#define TARGET_OS_XR 0
#define TARGET_OS_MACCATALYST 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_EMBEDDED 0
#define TARGET_OS_DRIVERKIT 0
#define TARGET_OS_WIN32 0
#define TARGET_OS_UNIX 0
#define TARGET_OS_NANO 0
#define TARGET_OS_OTHER 0

#define TARGET_CPU_ARM 0
#define TARGET_CPU_ARM64 1
#define TARGET_CPU_ARM64E 0
#define TARGET_CPU_X86 0
#define TARGET_CPU_X86_64 0
#define TARGET_CPU_PPC 0
#define TARGET_CPU_PPC64 0

#define TARGET_RT_64_BIT 1
#define TARGET_RT_LITTLE_ENDIAN 1
#define TARGET_RT_BIG_ENDIAN 0
#define TARGET_RT_MAC_MACHO 1
#define TARGET_RT_MAC_CFM 0

#endif /* __TARGETCONDITIONALS__ */
