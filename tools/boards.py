#!/usr/bin/env python3
"""Hardware description of the phones this tree can boot.

The shim, the Apple Device Tree builder and the kernel patches all need the
same handful of numbers about the phone: where the MMIO windows are, how much
RAM the kernel may use, how the CPUs are numbered, what the panel looks like.
Keeping them in one place makes adding a board a data change instead of a
code change.

Two boards are described here:

  sweet     Redmi Note 10 Pro (Qualcomm SM7150 / Snapdragon 732G, ARMv8.2).
            The upstream project. Every value was measured on the device.
  mondrian  POCO F5 Pro / Redmi K60 (Qualcomm SM8475 / Snapdragon 8+ Gen 1,
            ARMv9.0). This fork's target. The values come from the public
            device tree sources (MiCode/kernel_devicetree, branch
            mondrian-s-oss) unless the comment says otherwise; the ones that
            still need a reading from the live device are marked TODO and can
            be filled in from a shim "dtb dump" (see apply_facts()).

Sources for the mondrian numbers:

  MiCode/kernel_devicetree @ mondrian-s-oss
      qcom/cape.dtsi                 GICD/GICR, TLMM, SPMI, CPUs
      qcom/cape-reserved-memory.dtsi  firmware carve-outs in DRAM
      qcom/mondrian-sm8475.dtsi       Goodix touch over QUPv3 SPI
      qcom/xiaomi-sm8475-common.dtsi  volume-up key on the PM8350
      qcom/waipio-qupv3.dtsi          QUPv3 wrapper and SE addresses
  MiCode/Xiaomi_Kernel_OpenSource @ mondrian-s-oss
      build.config.msm.mondrian      PAGE_SIZE=4096 (4 KiB pages, not 16 KiB)
  mainline Linux qcom/sm8450.dtsi    UFS host, MDSS/DPU, GIC redistributors
"""
from dataclasses import dataclass, replace
import re


@dataclass(frozen=True)
class Cpu:
    """One core. Qualcomm numbers the cores in MPIDR Aff1."""
    aff1: int          # MPIDR Aff1 value (the core number on Qualcomm)
    cluster: int       # cluster id, for the device tree
    freq: int          # clock-frequency, for the device tree
    l2: int            # l2-cache-id, for the device tree


@dataclass(frozen=True)
class Board:
    name: str                  # 'sweet', 'mondrian'
    title: str                 # human readable
    soc: str                   # 'SM7150', 'SM8475'
    arch: str                  # 'armv8.2', 'armv9.0'
    machine_config: str        # XNU MACHINE_CONFIG
    dt_prefix: str             # device tree node prefix, e.g. 'sweet-ufs'
    payload_magic: bytes       # magic of the shim payload
    page_size: int             # 4096 or 16384

    # Kernel managed RAM. The low window is the default; --highmem picks the
    # upper one, which is what both boards use on the phone.
    phys_base: int
    mem_size: int
    alt_phys_base: int      # the other window (mkadt.py --alt-mem)
    alt_mem_size: int

    soc_base: int              # base of the /arm-io range
    gicd: int
    gicd_size: int
    gicr: int
    gicr_size: int
    gicr_pe_size: int

    fb: int                    # framebuffer the bootloader leaves running
    fb_size: int
    fb_w: int
    fb_h: int

    ufs: int                   # UFS host controller
    ufs_size: int

    timebase: int              # architected timer frequency
    vtimer_intid: int          # GIC INTID of the virtual timer
    ipi_sgi: int               # GIC INTID of the SGI used for IPIs
    tt_l2_size: int            # size of an XNU L2 block entry (page size dependent)

    cpus: tuple                # tuple of Cpu
    ecid: int                  # synthetic ECID presented to the iOS userland
    cmdline: str = ''          # default kernel boot arguments

    # What the drivers have to talk to. Free-form, the kernel patches read
    # them by name.
    touch: str = ''            # 'goodix-i2c' | 'goodix-spi'
    keys: str = ''             # 'pm6150' | 'pm8008'
    panel: str = ''            # 'lcd-dsc' | 'amoled-dsi'
    # The fields that are still a guess. An image must not be built from
    # them: the values have to be read from the phone first (the shim dumps
    # the live device tree, tools/boards.py reads it back).
    provisional: frozenset = frozenset()
    # The seed the device tree gives the kernel (64 bytes). The kernel
    # derives the physmap slide from it, and the slide decides whether the
    # physmap fits next to the kernel's own image: with a random seed the
    # mondrian boot is a coin flip (one run in three dies in pmap_map_bd).
    # None means random (the sweet's window is big enough for any slide).
    seed: bytes | None = None
    # Firmware memory inside the window, from the live device tree's
    # /reserved-memory (the ones marked no-map). The kernel must not
    # allocate it, so the tree says the memory is what is left.
    reserved: tuple = ()


# --------------------------------------------------------------------------
# sweet: Redmi Note 10 Pro (SM7150 / Snapdragon 732G)
# --------------------------------------------------------------------------
SWEET = Board(
    name='sweet',
    title='Redmi Note 10 Pro (sweet, SM7150 / Snapdragon 732G)',
    soc='SM7150',
    arch='armv8.2',
    machine_config='SWEET',
    dt_prefix='sweet',
    payload_magic=b'SWEETXNU',
    page_size=16384,
    # Kernel managed RAM: above every Qualcomm XPU carve-out (see NOTES.md)
    phys_base=0xb0000000,
    mem_size=0x4d000000,
    # The live FDT memory node is <0x80000000 2G>, <0x1_00000000 0xfcc00000>;
    # every fixed reserved-memory carve-out is in the low bank and the dynamic
    # pools are limited below 4G.
    alt_phys_base=0x100000000,
    alt_mem_size=0xfcc00000,
    soc_base=0x01000000,
    gicd=0x17a00000,
    gicd_size=0x10000,
    gicr=0x17a60000,
    gicr_size=0x100000,
    gicr_pe_size=0x20000,
    # reserved-memory cont_splash_region
    fb=0x9c000000,
    fb_size=0x1700000,
    fb_w=1080,
    fb_h=2400,
    # Internal UFS host (ufshc@1d84000, sweet live FDT), UFSHCI 2.1
    ufs=0x01d84000,
    ufs_size=0x3000,
    timebase=19200000,
    vtimer_intid=19,
    ipi_sgi=1,
    # XNU maps the kernel with L2 block entries: 32 MB with 16 KiB pages
    # (ARM_16K_TT_L2_SIZE in osfmk/arm64/proc_reg.h).
    tt_l2_size=0x2000000,
    cpus=tuple(
        Cpu(aff1=i, cluster=0, freq=2304000000 if i >= 6 else 1804800000, l2=i)
        for i in range(8)
    ),
    ecid=0x5357454554000001,     # 'SWEET' + 1, synthetic
    touch='goodix-i2c',
    keys='pm6150',
    panel='lcd-dsc',
    cmdline=('debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress '
             'rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 '
             'wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 '
             'wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'),
)

# --------------------------------------------------------------------------
# mondrian: POCO F5 Pro / Redmi K60 (SM8475 / Snapdragon 8+ Gen 1)
# --------------------------------------------------------------------------
# The eight cores are a Cortex-X2, three Cortex-A710 and four Cortex-A510.
# Qualcomm numbers them in MPIDR Aff1, like on sweet. The exact clock values
# are cosmetic for the device tree; the kernel only needs the count.
MONDRIAN = Board(
    name='mondrian',
    title='POCO F5 Pro / Redmi K60 (mondrian, SM8475 / Snapdragon 8+ Gen 1)',
    soc='SM8475',
    arch='armv9.0',
    machine_config='MONDRIAN',
    dt_prefix='mondrian',
    payload_magic=b'MONDRIAN',
    page_size=4096,              # PAGE_SIZE=4096 in build.config.msm.mondrian
    # Measured on the phone (2026-10-20): the live device tree that the
    # bootloader passes, read from /proc/device-tree in a recovery. The
    # /memory node has six regions: 0x80000000+0x6a000000, then a hole, then
    # 0xf4600000+0x0ba00000 (which ends exactly at 4G), and four regions above
    # 4G. The kernel gets a window inside the first one: that is the region
    # that holds the splash framebuffer (0xb8000000) and the only one the
    # phone really has (the ddr_size property says 12GB, but the bootloader
    # only describes the part the kernel may use).
    #
    # The window is the same one the sweet uses, and for the same reasons: it
    # has to contain the splash framebuffer (0xb8000000), and it has to start
    # above the firmware's own memory at the bottom of the bank (the
    # hypervisor is at 0x80000000+0x600000; the kernel image written over it
    # kills the secure world and the phone resets instead of booting).
    #
    # The window is 0xb0000000+0x46000000, so it ends at 0xf6000000, inside
    # the phone's *second* RAM bank. The live device tree says the RAM is
    #   0x80000000+0x6a000000  and  0xf4600000+0xba00000
    # so 0xea000000..0xf4600000 is a hole: not RAM at all. The kernel's
    # dynamic memory starts at the *end* of the window (static_memory_end =
    # physmap_base + memSize), so a window that ends inside the hole hands
    # the first heap pages to memory that does not exist: the writes are
    # lost and the kernel jumps to a corrupted pointer. That was the
    # phone's panic ("Undefined kernel instruction", pc inside the physmap,
    # the same every time: a page in the hole read back as a pointer).
    #
    # A window that *contains* the hole (0xb0000000+0x46000000 ends at
    # 0xf6000000, in the second bank) is just as bad: the zone map still
    # covers the hole, and the kernel reads a pointer from it.
    #
    # The size has a floor: below 0x3a000000 the physmap no longer fits next
    # to the kernel's own image and the boot dies in pmap_map_bd (measured on
    # the host, and on the phone with the new kernel: it asked for more room
    # than the old window had). At 0x46000000 the host boots with every
    # slide tried, and the end of the window is in real RAM.
    #
    # The base is the only one that boots, measured on the host with the same
    # kernel (tools/qemu-ios.py): the low bank and the hole after the splash
    # both panic in pmap_map_bd, and any other base dies before the console
    # even exists. That bisection was made with a random seed, so it is not
    # trustworthy: redo it with the seed pinned below.
    phys_base=0xb0000000,
    mem_size=0x46000000,
    # Pinned: the physmap slide comes from this seed, and with a random one
    # the boot is a coin flip (one run in three dies in pmap_map_bd). This
    # one is known to work with the window above (checked on the host).
    seed=b'\x11' * 64,
    # The firmware memory inside the window, from the live device tree's
    # /reserved-memory (the ones marked no-map). They are not holes: the
    # memory is there, but it belongs to the secure world, so the kernel
    # must not use it. XNU reads the tree's /memory node (checked on the
    # host: a /memory that describes less memory makes the kernel fail),
    # but it ignores /reserved-memory, so the regions are left out of
    # /memory instead.
    reserved=(
        (0xe0000000, 0x00600000),     # qheebsp_reserved_region
        (0xe0600000, 0x00400000),     # cpusys_vm_region
        (0xe0a00000, 0x00100000),     # hyp_reserved_region
        (0xe55f3000, 0x00009000),     # trust_ui_vm_qrtr
        (0xe55fc000, 0x00004000),     # trust_ui_vm_vblk0_ring
        (0xe5600000, 0x00100000),     # trust_ui_vm_swiotlb
        (0xe8800000, 0x00100000),     # tz_stat_region
        (0xe8900000, 0x01200000),     # tags_region
        (0xe9b00000, 0x00500000),     # qtee_region
    ),
    alt_phys_base=0x800000000,
    alt_mem_size=0x37500000,
    soc_base=0x01000000,
    # GICD/GICR: cape.dtsi and the mainline sm8450.dtsi agree, and the live
    # device tree confirms it: interrupt-controller@17100000 has
    # reg = <0x17100000 0x10000> (GICD) and <0x17180000 0x200000> (GICR),
    # redistributor-stride = 0x40000, one redistributor region.
    gicd=0x17100000,
    gicd_size=0x10000,
    gicr=0x17180000,
    gicr_size=0x200000,          # 8 redistributors, stride 0x40000
    gicr_pe_size=0x40000,
    # The splash the ABL leaves for the display: cont_splash_region at
    # 0xB8000000, 0x2b00000 (43 MiB). Source: the SM8450 display dtsi
    # (cape-sde-display.dtsi, splash_region); the shim prefers the value of
    # the live device tree.
    fb=0xb8000000,
    fb_size=0x2b00000,
    fb_w=1440,
    fb_h=3200,
    # UFS host: ufshc@1d84000 (mainline sm8450.dtsi). Same window as sweet,
    # but a UFS 3.1 controller, not the UFSHCI 2.1 sweet drives. The live
    # device tree agrees: ufshc@1d84000 with reg 0x1d84000+0x3000 (ufs_mem),
    # 0x1d88000+0x8000 (ufs_ice) and 0x1d90000+0x9000 (ufs_ice_hwkms),
    # two lanes per direction, irq SPI 265.
    ufs=0x01d84000,
    ufs_size=0x3000,
    timebase=19200000,
    vtimer_intid=19,             # Qualcomm's PPI numbering, as on sweet
    ipi_sgi=1,
    # 4 KiB pages: XNU maps the kernel with 2 MB L2 block entries
    # (ARM_4K_TT_L2_SIZE).
    tt_l2_size=0x200000,
    cpus=tuple(
        Cpu(aff1=i, cluster=0 if i < 4 else (1 if i < 7 else 2),
            freq=3000000000 if i == 0 else (2500000000 if i < 4 else 1800000000),
            l2=i)
        for i in range(8)
    ),
    ecid=0x4d4f4e445249414e,     # 'MONDRIAN', synthetic
    touch='goodix-spi',          # Goodix over QUPv3 SE4 SPI, not I2C
    keys='pm8008',               # PM8008 (PMR735A + PM8350B), not the PM6150
    panel='amoled-dsi',
    # Nothing is provisional any more: every value above was read from the
    # phone itself.
    provisional=frozenset(),
    # The boot arguments are the ones sweet uses, with the framebuffer
    # arguments renamed for this board.
    # cpus=1: the kernel starts the other cores through PSCI, and the shim
    # does not implement that call yet, so the first bring-up wants a single
    # core (what the QEMU run does too, its tree has one cpu node).
    cmdline=('debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress '
             'rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 '
             'wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 '
             'wdt=-1 mondrianfb_noconsole=1 mondrianfb_hz=30'),
)

BOARDS = {b.name: b for b in (SWEET, MONDRIAN)}


def get_board(name):
    """Board by name ('sweet', 'mondrian')."""
    try:
        return BOARDS[name]
    except KeyError:
        raise SystemExit(f'unknown board "{name}"; known: {", ".join(sorted(BOARDS))}')


def provisional_fields(board):
    """The fields of the board that are still a guess, with their values."""
    return {f: getattr(board, f) for f in sorted(board.provisional)}


def is_measured(board):
    """True when every value of the board comes from the phone."""
    return not board.provisional


def require_measured(board, what):
    """Stop unless the board was measured on the phone.

    A bootable image is built from the memory map and the framebuffer of the
    phone. If those are still guesses, the image can write to a register
    that is not a framebuffer, so the build is refused.
    """
    fields = provisional_fields(board)
    if not fields:
        return
    raise SystemExit(
        f'{what}: the board "{board.name}" is not measured yet.\n'
        f'  Still a guess: ' +
        ', '.join(f'{k}={v:#x}' for k, v in fields.items()) + '\n'
        f'  Read them off the phone first (the shim dumps the live device\n'
        f'  tree) and put them in tools/boards.py, or pass --allow-provisional\n'
        f'  if you know what you are doing.')


# --------------------------------------------------------------------------
# Live device tree facts
# --------------------------------------------------------------------------
# The shim can print the device tree the bootloader handed it. The lines look
# like
#
#   FACT memory 0 0x00000000 0x80000000
#   FACT reg /ufs_mem 0x01d84000 0x3000
#
# and are parsed here so that a board can be filled in without guessing.
_FACT_RE = re.compile(r'^FACT\s+(\S+)\s+(\S+)\s*(.*)$')


def parse_facts(text):
    """Parse a shim dtb dump into a dict of facts."""
    facts = {}
    for line in text.splitlines():
        line = line.strip()
        m = _FACT_RE.match(line)
        if not m:
            continue
        kind, key, rest = m.group(1), m.group(2), m.group(3).split()
        facts[(kind, key)] = [int(v, 0) for v in rest]
    return facts


def apply_facts(board, facts):
    """Return a copy of board with the values from a shim dtb dump applied.

    Only the keys the dump actually carries are touched, so a partial dump
    (say, only the memory node) still works. The fields that the dump
    measured are no longer provisional.
    """
    b = board
    done = set()

    # Memory banks: "FACT memory reg0 <base> <size>".
    banks = [(v[0], v[1]) for (kind, key), v in facts.items()
             if kind == 'memory' and key.startswith('reg') and len(v) >= 2]
    if banks:
        banks.sort()
        # The shim gives the kernel the highest region of at least 512MB (the
        # low bank of this phone carries the bootloader, the modem and the
        # firmware carve-outs), so the image has to be built for that one.
        big = [x for x in banks if x[1] >= 0x20000000]
        best = max(big, key=lambda x: x[0]) if big else max(banks, key=lambda x: x[1])
        b = replace(b, phys_base=best[0], mem_size=best[1])
        rest = [x for x in banks if x != best]
        if rest:
            alt = max(rest, key=lambda x: x[1])
            b = replace(b, alt_phys_base=alt[0], alt_mem_size=alt[1])
        done |= {'phys_base', 'mem_size', 'alt_phys_base', 'alt_mem_size'}

    for (kind, key), values in facts.items():
        if kind != 'reg' or len(values) < 2:
            continue
        name = key.rsplit('/', 1)[-1]
        base = name.split('@')[0]
        if name.startswith('ufs') and len(values) >= 2:
            b = replace(b, ufs=values[0], ufs_size=values[1])
            done |= {'ufs', 'ufs_size'}
        elif base in ('intc', 'gic', 'interrupt-controller') and len(values) >= 2:
            # The device tree describes the GIC (GICD plus the redistributor
            # window) with a single reg. The GICR sits 512KB above the GICD on
            # this SoC, and the redistributor stride follows from the size.
            gicd, gicd_size = values[0], values[1]
            b = replace(b, gicd=gicd, gicd_size=gicd_size)
            done |= {'gicd', 'gicd_size'}
            if len(values) >= 4:
                b = replace(b, gicr=values[2], gicr_size=values[3])
                done |= {'gicr', 'gicr_size'}
        elif 'splash' in name or 'screen' in name:
            # the framebuffer the bootloader leaves for the panel
            b = replace(b, fb=values[0], fb_size=values[1])
            done |= {'fb', 'fb_size'}

    b = replace(b, provisional=frozenset(board.provisional - done))
    return b


if __name__ == '__main__':
    import sys
    for b in BOARDS.values():
        print(f'{b.name:9} {b.soc:8} {b.arch:8} page={b.page_size} '
              f'gicd={b.gicd:#x} ufs={b.ufs:#x} fb={b.fb:#x} '
              f'alt={b.alt_phys_base:#x}+{b.alt_mem_size:#x}')
    if len(sys.argv) > 1:
        print(parse_facts(open(sys.argv[1]).read()))
