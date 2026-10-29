#!/usr/bin/env python3
"""Apply the SWEET bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo ios-root-tweaks.py MOUNTED_ROOT [--ui-hook DYLIB] [--gpu-test DYLIB]
                                 [--mesa-test DYLIB] [--mesa STAGE_DIR]

MONDRIAN_INSTALL_ONLY=1 copies the dylibs and Mesa and skips the rest of the
bring-up, which is already in the image; that works on a noowners mount
without root.

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter jobs removed (no baseband: it
                  crash-loops and Setup blocks on its CoreTelephony XPC)
  containers      /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}
                  (on iOS they live on the data volume)
  preboot         /private/preboot/<boot-manifest-hash>/usr/standalone/firmware,
                  a copy of the firmware: launchd bind-mounts it from there
  swap            /private/var/vm (the dynamic pager cannot open a swap file
                  without the directory)
  migration       LastSystemVersion so DataMigration does not run for an hour
                  on every boot
  audio           VirtualAudio HAL plug-in disabled (mediaserverd crash)
  MediaToolbox    StartRecorderServer=false (camera filter prewarm calls a
                  NULL OpenGL function without a GPU -> mediaserverd crash loop)
  SpringBoard     BKNoWatchdogs (one slow CPU path, no scene-create watchdog
                  kills), no cloud-configuration UI
  Setup           skipped: SetupDone, SetupFinishedAllSteps, SetupVersion 11,
                  mini-buddy flags off
  activation      mobileactivationd data ark seeded; the actual Activated state
                  comes from its Hactivation branch, selected by the /chosen
                  security-status properties in tools/mkadt.py
  dylibs          --ui-hook copies a dylib to the image as
                  /usr/libexec/mondrian-ui-hook.dylib: the kernel appends
                  DYLD_INSERT_LIBRARIES for it to
                  containermanagerd/backboardd/SpringBoard when the boot
                  argument mondrian_ui_hook selects them. --gpu-test copies
                  /usr/libexec/mondrian-gpu-test.dylib, which the UI hook
                  dlopens when it is there. --mesa-test copies the Mesa
                  smoke test the same way. --mesa copies libOSMesa.8.dylib
                  from the directory tools/mk-mesa-ios.sh stages into
                  /usr/lib, where its install name points.
"""
import glob, hashlib, os, plistlib, shutil, sys

BUILD, VERSION = '20H392', '16.7.16'
MOBILE = 501


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def merge_pref(root, name, values):
    """Merge keys into /var/mobile/Library/Preferences/NAME.plist (mobile, 0600)."""
    path = os.path.join(root, 'private/var/mobile/Library/Preferences', name + '.plist')
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, MOBILE, MOBILE, 0o600)
    print('pref', name, sorted(values))


def launchd(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    removed = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
    for k in removed:
        del jobs[k]
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, {len(removed)} CommCenter jobs removed')


def containers(root):
    base = os.path.join(root, 'private/var/containers')
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            os.makedirs(d)
            os.chown(d, uid, uid)
            os.chmod(d, 0o755)
            print('mkdir', d)


# The boot-manifest hash the ADT publishes (tools/mkadt.py hashes the same
# string). launchd builds /private/preboot/<hash> from it and bind-mounts
# /usr/standalone/firmware from there; a flattened root has no preboot volume.
BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').hexdigest().upper()


def preboot(root):
    src = os.path.join(root, 'usr/standalone/firmware')
    dst = os.path.join(root, 'private/preboot', BOOT_MANIFEST_HASH,
                       'usr/standalone/firmware')
    if not os.path.isdir(src) or os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst))
    shutil.copytree(src, dst)
    for dirpath, dirnames, filenames in os.walk(dst):
        os.chown(dirpath, 0, 0)
        os.chmod(dirpath, 0o755)
        for name in filenames:
            f = os.path.join(dirpath, name)
            os.chown(f, 0, 0)
            os.chmod(f, 0o644)
    print('preboot', os.path.relpath(dst, root))


def swapdir(root):
    d = os.path.join(root, 'private/var/vm')
    if not os.path.isdir(d):
        os.makedirs(d)
        os.chown(d, 0, 0)
        os.chmod(d, 0o755)
        print('mkdir', d)


def find_container(root, kind, identifier):
    for meta in glob.glob(os.path.join(root, 'private/var/containers', kind, '*',
                                       '.com.apple.mobile_container_manager.metadata.plist')):
        if load(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def activation(root):
    c = find_container(root, 'Data/System', 'com.apple.mobileactivationd')
    if c is None:
        print('warning: no mobileactivationd system container in the image; skipped data ark')
        return
    d = os.path.join(c, 'Library/internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    os.chmod(d, 0o755)
    save(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('data ark', d)


def audio(root):
    src = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    dst_dir = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
    if os.path.exists(src):
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, dst_dir)
        print('VirtualAudio.plugin disabled')
    for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        st = os.stat(conf)
        data = load(conf)
        data['StartRecorderServer'] = False
        save(conf, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, plistlib.FMT_XML)
        print('StartRecorderServer off', os.path.relpath(conf, root))


# --option: (file name in /usr/libexec, what the messages call it). The UI hook
# is the one the kernel injects; the GPU test is dlopened by the UI hook.
DYLIB_OPTIONS = {
    '--ui-hook': ('mondrian-ui-hook.dylib', 'UI hook'),
    '--gpu-test': ('mondrian-gpu-test.dylib', 'GPU test'),
    '--mesa-test': ('mondrian-mesa-test.dylib', 'Mesa test'),
}


def set_owner(path):
    """Root ownership is what iOS ships, but these images are built noowners:
    the volume does not track it and chown is not permitted on it."""
    try:
        os.chown(path, 0, 0)
    except PermissionError:
        pass


def install_dylib(root, source, name, what):
    """Copy one dylib into /usr/libexec, owned by root, mode 0755."""
    directory = os.path.join(root, 'usr/libexec')
    os.makedirs(directory, exist_ok=True)
    destination = os.path.join(directory, name)
    shutil.copyfile(source, destination)
    set_owner(destination)
    os.chmod(destination, 0o755)
    print('installed', os.path.relpath(destination, root))


# --mesa takes the stage directory tools/mk-mesa-ios.sh prints; its library
# goes to /usr/lib because that is its install name.
MESA_OPTION = '--mesa'
MESA_LIBRARY = 'libOSMesa.8.dylib'


def install_mesa(root, source):
    """Copy Mesa's libOSMesa from a staged tree into /usr/lib."""
    library = os.path.join(source, MESA_LIBRARY)
    directory = os.path.join(root, 'usr/lib')
    os.makedirs(directory, exist_ok=True)
    destination = os.path.join(directory, MESA_LIBRARY)
    shutil.copyfile(library, destination)
    set_owner(destination)
    os.chmod(destination, 0o755)
    print('installed', os.path.relpath(destination, root))


def parse_args(argv):
    """MOUNTED_ROOT, then each --option DYLIB at most once, in any order."""
    if not argv or argv[0].startswith('-'):
        sys.exit(__doc__)
    root, rest, options = argv[0], argv[1:], {}
    while rest:
        known = rest[0] in DYLIB_OPTIONS or rest[0] == MESA_OPTION
        if not known or rest[0] in options or len(rest) < 2:
            sys.exit(__doc__)
        options[rest[0]] = rest[1]
        rest = rest[2:]
    return root, options


def main():
    root, options = parse_args(sys.argv[1:])
    if not os.path.isdir(os.path.join(root, 'System/Library/xpc')):
        sys.exit(__doc__)
    for option, source in options.items():
        if option == MESA_OPTION:
            if not os.path.isfile(os.path.join(source, MESA_LIBRARY)):
                sys.exit(f'error: Mesa library not found: {source}')
        elif not os.path.isfile(source):
            sys.exit(f'error: {DYLIB_OPTIONS[option][1]} not found: {source}')
    if os.environ.get('MONDRIAN_INSTALL_ONLY') != '1':
        launchd(root)
        containers(root)
        preboot(root)
        swapdir(root)
        activation(root)
        audio(root)
    for option, (name, what) in DYLIB_OPTIONS.items():
        if option in options:
            install_dylib(root, options[option], name, what)
    if MESA_OPTION in options:
        install_mesa(root, options[MESA_OPTION])
    if os.environ.get('MONDRIAN_INSTALL_ONLY') == '1':
        return
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    merge_pref(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False})
    merge_pref(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
        'daemonizeNeedsToRun': False})
    merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
        k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy',
                           'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
                           'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                           'SilentICDPUpgrade')})
    merge_pref(root, 'com.apple.managedconfiguration.notbackedup', {
        'LockdownActivationIndicatesCloudConfigurationAvailable': False})


if __name__ == '__main__':
    main()
