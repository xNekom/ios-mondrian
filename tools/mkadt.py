#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the board description in tools/boards.py, which in turn is
taken from the live device tree of the phone.

Usage:  mkadt.py OUT.adt [--dump] [--qemu] [--altmem] [--board NAME]
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402
import boards  # noqa: E402

# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76): GICD/GICR and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27
# The window of the QEMU "virt" machine: its RAM starts at 0x40000000, so the
# kernel goes there whatever the board says.
import os
# The window the kernel gets in the QEMU run; the environment overrides it
# to try the phone's own window without touching the board table.
QEMU_PHYS_BASE = int(os.environ.get('QEMU_PHYS_BASE', '0xb0000000'), 0)
QEMU_MEM_SIZE = int(os.environ.get('QEMU_MEM_SIZE', '0x4d000000'), 0)
# Panic log buffer, carved from the TOP of the dram range and exposed to XNU
# as /pram + /chosen/embedded-panic-log-size. Without it pe_init.c's
# check_for_panic_log() leaves gPanicBase == 0, debug_log_init() fails twice
# ("debug_log_init: Error!! gPanicBase is still not initialized") and the
# kernel hangs right after "kdp_core zlib memory" -- reproduced on QEMU here
# and independently on ios-fajita upstream (commit 1664d63).
PANIC_LOG_SIZE = 0x100000
# How many CPU nodes the tree declares (0 = the board's own count). The first
# bring-up on a new phone wants one: the kernel starts the other cores
# through PSCI, and the shim does not implement that call yet.
DT_CPUS = int(os.environ.get('DT_CPUS', '0'), 0)

BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real D22AP tree, without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


def build(board, seed=None, qemu=False, altmem=False):
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-ios.py)."""
    phys_base, mem_size = ((board.alt_phys_base, board.alt_mem_size) if altmem
                           else (board.phys_base, board.mem_size))
    if qemu:
        phys_base, mem_size = QEMU_PHYS_BASE, QEMU_MEM_SIZE
    # Carve the panic log off the top so the kernel never allocates over it.
    panic_base = phys_base + mem_size - PANIC_LOG_SIZE
    mem_size -= PANIC_LOG_SIZE
    gicd, gicr, timebase = ((QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu
                            else (board.gicd, board.gicr, board.timebase))
    seed = seed if seed is not None else board.seed
    if seed is None:
        seed = os.urandom(64)
    # ADT_SEED=<hex> pins it. The kernel derives the physmap slide from this
    # seed, and the slide decides whether the physmap fits next to the
    # kernel's own image: with a random seed the boot is a coin flip (the
    # host panics in pmap_map_bd about one run in three). A pinned seed
    # makes the boot reproducible, which is what the phone needs to match
    # the host.
    if 'ADT_SEED' in os.environ:
        seed = bytes.fromhex(os.environ['ADT_SEED'].replace(' ', ''))
        assert len(seed) == 64, 'ADT_SEED must be 64 bytes of hex'
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        ('debug-enabled', u32(1)),
        ('embedded-panic-log-size', u32(PANIC_LOG_SIZE)),
        ('firmware-version', cstr(board.name + '-shim')),
        ('system-firmware-version', cstr(board.name + '-shim')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. 1080x2400 @3x =
        # 360x800 points (like iPhone X class devices).
        ('display-scale', u32(3)),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', board.ecid)),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # SMP: all eight cores in physical-core order. The kernel defaults to one
    # and uses cpus=N to select an initial prefix (N <= 8).
    # QEMU retains its original single-CPU tree: its MPIDRs differ from sweet.
    cpu_compat = {'sweet': cstr('qcom,kryo470') + cstr('ARM,v8'),
                  'mondrian': cstr('qcom,kryo') + cstr('ARM,v9')}
    cpu_nodes = []
    n_cpus = 1 if qemu else len(board.cpus)
    if DT_CPUS:
        n_cpus = max(1, min(DT_CPUS, len(board.cpus)))
    for core in range(n_cpus):
        cpu = board.cpus[core]
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            ('compatible', cpu_compat.get(board.name, cpu_compat['sweet'])),
            ('reg', u32(cpu.aff1 << 8)),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),        # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(cpu.cluster)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(cpu.l2)),  # distinct per-core L2 nodes in live FDT
            ('l3-cache-id', u32(0)),     # shared L3
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(cpu.freq)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else board.vtimer_intid)),
        ('reg', u64(gicd - board.soc_base, board.gicd_size,
                    gicr - board.soc_base, board.gicr_size)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr(board.dt_prefix + '-io')),
        ('compatible', cstr(board.dt_prefix + '-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, board.soc_base, 0x100000000 - board.soc_base)),
    ], [gic,
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node; it
        # matches the panel in the framebuffer driver, which copies layers
        # 1:1 and does not scale.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr(board.dt_prefix + ',display')),
            ('canvas-width', u32(board.fb_w)),
            ('canvas-height', u32(board.fb_h)),
        ])])

    fbcon = node(board.dt_prefix + '-fbcon', [
        ph(),
        ('reg', u64(board.fb, board.fb_size)),
        ('width', u32(board.fb_w)),
        ('height', u32(board.fb_h)),
        ('stride', u32(board.fb_w * 4)),
    ])

    # bsd/dev/<board>_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node(board.dt_prefix + '-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(board.ufs, board.ufs_size)),
    ])

    # The global clock controller: the UFS host's clock is a branch of it,
    # and the bootloader leaves that branch off (the host's registers read
    # as zero). The branch number is in the property, so the driver does not
    # have to know it.
    gcc = node(board.dt_prefix + '-gcc', [
        ph(),
        ('compatible', cstr('qcom,gcc')),
        ('reg', u64(board.gcc, 0x1000)),
        ('ufs-branch', u32(board.ufs_gcc_branch)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product()
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Identity of the iPhone X whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP), model is hw.machine/hw.product
    # (iPhone10,3). 'xiaomi,<board>' stays for the platform expert matching.
    # The RAM the kernel gets, as the phone's own device tree states it.
    # XNU reads this node (checked on the host: a /memory that describes
    # less memory than the window makes the kernel fail), but it ignores
    # /reserved-memory.
    # ADT_MEMORY=0 leaves the node out (the sweet's tree has no /memory).
    # ADT_MEM_SIZE=<hex> makes the node describe less memory than the
    # window, to see whether the kernel reads this node at all.
    # ADT_MEM_RESERVED=1 leaves the firmware's regions out of it. XNU dies
    # in pmap_map_bd with the gaps that makes, so it is off by default.
    adt_mem_size = int(os.environ.get('ADT_MEM_SIZE', '0'), 0) or mem_size
    regions = []
    if adt_mem_size:
        regions = [(phys_base, adt_mem_size)]
        if os.environ.get('ADT_MEM_RESERVED') == '1':
            left = list(regions)
            for rb, rs in board.reserved:
                rest = []
                for b, s in left:
                    if rb >= b + s or rb + rs <= b:
                        rest.append((b, s))
                        continue
                    if b < rb:
                        rest.append((b, rb - b))
                    if rb + rs < b + s:
                        rest.append((rb + rs, b + s - (rb + rs)))
                left = rest
            regions = left
    # The node is off by default: XNU dies in pmap_map_bd when the tree
    # describes the window and the seed's slide does not fit that shape
    # (the host reference has to boot), and the sweet's tree has none
    # either. The kernel gets the window from the boot arguments.
    memory = [] if os.environ.get('ADT_MEMORY', '0') == '0' else [
        node('memory', [
            ph(),
            ('device_type', cstr('memory')),
            ('reg', b''.join(u64(b, s) for b, s in regions)),
        ])]

    # Firmware memory the kernel must not touch. The phone's device tree
    # marks 38 regions no-map; the ones inside the window are copied here.
    # ADT_RESERVED=all reserves the whole window (a test: if the kernel
    # cannot map its own image any more, it read this node).
    reserved = []
    if os.environ.get('ADT_RESERVED') == 'all':
        reserved = [node('reserved-memory', [
            ph(),
            ('#address-cells', u32(2)),
            ('#size-cells', u32(2)),
        ], [node('test-reserved', [
            ph(),
            ('reg', u64(phys_base, mem_size)),
            ('no-map', b''),
        ])])]

    # Panic log region. reg = <phys size>; it sits just above the dram-size
    # we expose, so XNU maps it but never allocates into it.
    pram = node('pram', [ph(), ('reg', u64(panic_base) + u64(PANIC_LOG_SIZE))])

    return node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,' + board.name) +
         cstr('qcom,' + board.soc.lower()) + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons, pram] + memory + reserved + product + ([] if qemu else [ufs, gcc]))


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('out')
    ap.add_argument('--board', default='sweet', help='sweet | mondrian')
    ap.add_argument('--qemu', action='store_true', help='QEMU virt addresses')
    ap.add_argument('--altmem', action='store_true', help='use the upper DDR bank')
    ap.add_argument('--facts', help='shim dtb dump to take the memory map from')
    ap.add_argument('--allow-provisional', action='store_true',
                    help='build even if the board still has guessed values')
    ap.add_argument('--dump', action='store_true', help='print the tree')
    a = ap.parse_args()

    board = boards.get_board(a.board)
    if a.facts:
        board = boards.apply_facts(board, boards.parse_facts(open(a.facts).read()))
    if not a.allow_provisional and not a.qemu:
        # the QEMU memory is synthetic, the phone's is not
        boards.require_measured(board, 'mkadt.py')
    root = build(board, qemu=a.qemu, altmem=a.altmem)
    blob = adt.serialize(root)
    open(a.out, 'wb').write(blob)
    if a.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{a.out}: {len(blob)} bytes', file=sys.stderr)
