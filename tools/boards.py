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
    high_phys_base: int
    high_mem_size: int

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
    high_phys_base=0x100000000,
    high_mem_size=0xfcc00000,
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
    payload_magic=b'MONDXNU',
    page_size=4096,              # PAGE_SIZE=4096 in build.config.msm.mondrian
    # TODO(mondrian): the low bank carries the bootloader, the modem and the
    # other firmware carve-outs (cape-reserved-memory.dtsi), so the kernel
    # must live above 4G. The size is a placeholder until the live device
    # tree is read (see apply_facts and docs/MONDIAN_PORT.md).
    phys_base=0x00000000,
    mem_size=0x80000000,
    high_phys_base=0x100000000,
    high_mem_size=0xe8000000,     # TODO(mondrian): measure on the device
    soc_base=0x01000000,
    # GICD/GICR: cape.dtsi and the mainline sm8450.dtsi agree.
    gicd=0x17100000,
    gicd_size=0x10000,
    gicr=0x17180000,
    gicr_size=0x200000,          # 8 redistributors, stride 0x40000
    gicr_pe_size=0x40000,
    # TODO(mondrian): the ABL splash of a DSI panel. sweet's LCD left its
    # framebuffer at 0x9c000000; on SM8475 the display subsystem is MDSS
    # (0x0ae00000) with a DPU (0x0ae01000) and the panel is driven over
    # DSI D-PHY, so the address has to be read from the device.
    fb=0x9c000000,
    fb_size=0x1700000,
    fb_w=1440,
    fb_h=3200,
    # UFS host: ufshc@1d84000 (mainline sm8450.dtsi). Same window as sweet,
    # but a UFS 3.1 controller, not the UFSHCI 2.1 sweet drives.
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
    # Not measured yet: the memory map of the phone and the framebuffer the
    # bootloader leaves for a DSI panel. No bootable image may be built from
    # these.
    provisional=frozenset({'phys_base', 'mem_size', 'high_phys_base',
                           'high_mem_size', 'fb', 'fb_size'}),
    # The boot arguments are the ones sweet uses, with the framebuffer
    # arguments renamed for this board. cpus=6 starts the six A710/A510
    # cores and leaves the X2 and the other A710s parked, like sweet leaves
    # the two A76s parked.
    cmdline=('debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress '
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
        b = replace(b, phys_base=banks[0][0], mem_size=banks[0][1])
        high = [x for x in banks if x[0] >= 0x100000000]
        if high:
            b = replace(b, high_phys_base=high[-1][0], high_mem_size=high[-1][1])
        done |= {'phys_base', 'mem_size', 'high_phys_base', 'high_mem_size'}

    for (kind, key), values in facts.items():
        if kind != 'reg' or len(values) < 2:
            continue
        name = key.rsplit('/', 1)[-1]
        if name.startswith('ufs') and len(values) >= 2:
            b = replace(b, ufs=values[0], ufs_size=values[1])
            done |= {'ufs', 'ufs_size'}
        elif name in ('intc', 'gic') and len(values) >= 4:
            # GICD, GICD size, GICR, GICR size
            b = replace(b, gicd=values[0], gicd_size=values[1],
                        gicr=values[2], gicr_size=values[3])
            done |= {'gicd', 'gicd_size', 'gicr', 'gicr_size'}
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
              f'ram={b.high_phys_base:#x}+{b.high_mem_size:#x}')
    if len(sys.argv) > 1:
        print(parse_facts(open(sys.argv[1]).read()))
