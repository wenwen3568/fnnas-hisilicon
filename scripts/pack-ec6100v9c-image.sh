#!/usr/bin/env bash
#
# pack-ec6100v9c-image.sh - build an EC6100V9C (Hi3798MV100) eMMC image in the
# STOCK bootloader's partition layout, using the board's own kernel (and thus
# its own drivers: hieth / himciv200 / mali-utgard / hisi-ion / hi-aiao ...).
#
# Everything here was verified against a running EC6100V9C:
#
#   p2 (U-Boot env, byte offset 1 MiB) says:
#     bootcmd  = mmc read 0 0x1FFFFC0 0x7000 0xA000; bootm 0x1FFFFC0
#     bootargs = ... root=/dev/mmcblk0p9 rootfstype=ext4 rootwait
#                 blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),
#                             4M(pqparam),4M(logo),20M(kernel),64M(busybox),
#                             512M(backup),-(ubuntu)
#   fdisk -l shows NO partition table: the partition map comes from blkdevparts
#   in the kernel command line, so files must land at exact byte offsets.
#
#   Layout (MiB):
#      0  fastboot.bin      bootloader (sector 0x0,   length 0x440 sectors)
#      1  bootargs.bin      U-Boot env  (sector 0x800, length 0x80 sectors)
#      2  baseparam.img     (sector 0x1000)
#      6  pq_param.bin      (sector 0x3000)
#     10  logo.img          (sector 0x5000)
#     14  KERNEL  uImage    (sector 0x7000, bootcmd reads 0xA000 sectors = 20 MiB)
#     34  busybox ext4 64M  (sector 0x11000)
#     98  backup  ext4 512M (sector 0x31000)
#    610  ubuntu  ext4 rest (root=/dev/mmcblk0p9)  <- the system files go here
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
PREBUILT="$repo/prebuilt/mv100-ec6100v9c"

KERNEL="$PREBUILT/hi_kernel.bin"
ROOTFS=""
BOOTARGS=""
OUT="$repo/out/ec6100v9c-vendor.img"
SIZE_MIB=7456                      # 7818182656 B = 7.29 GiB, the real eMMC
FSCK=auto                          # auto|always|never
ALLOW_FOREIGN=0
WITH_BOOTLOADER=1

MIB=$((1024 * 1024))
OFF_BOOTARGS=$((1 * MIB))
OFF_BASEPARAM=$((2 * MIB))
OFF_PQPARAM=$((6 * MIB))
OFF_LOGO=$((10 * MIB))
OFF_KERNEL=$((14 * MIB))
KERNEL_MAX=$((20 * MIB))
OFF_BUSYBOX=$((34 * MIB));  LEN_BUSYBOX=$((64 * MIB))
OFF_BACKUP=$((98 * MIB));   LEN_BACKUP=$((512 * MIB))
OFF_ROOTFS=$((610 * MIB))

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Usage: $(basename "$0") --rootfs DIR [options]

  --rootfs DIR          directory tree to place in p9 (REQUIRED)
  --kernel FILE         uImage to place in p6   (default: prebuilt vendor kernel)
  --bootargs FILE       raw 64 KiB env blob     (default: generate from the live env)
  --out FILE            output image            (default: $OUT)
  --size-mib N          image size in MiB       (default: $SIZE_MIB)
  --fsck auto|always|never                       (default: auto)
  --no-bootloader       skip fastboot.bin at offset 0 (keep the box's own)
  --allow-foreign       don't abort on a non-armhf rootfs / non-ARM kernel
EOF
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rootfs) ROOTFS="$2"; shift 2;;
    --kernel) KERNEL="$2"; shift 2;;
    --bootargs) BOOTARGS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --size-mib) SIZE_MIB="$2"; shift 2;;
    --fsck) FSCK="$2"; shift 2;;
    --no-bootloader) WITH_BOOTLOADER=0; shift;;
    --allow-foreign) ALLOW_FOREIGN=1; shift;;
    -h|--help) usage;;
    *) echo "unknown option: $1" >&2; usage;;
  esac
done

[ -n "$ROOTFS" ] || usage
[ -d "$ROOTFS" ] || die "rootfs directory not found: $ROOTFS"
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"

command -v mke2fs >/dev/null || die "mke2fs (e2fsprogs) is required"
command -v dd >/dev/null || die "dd is required"

TOTAL_MIB=$SIZE_MIB
[ "$SIZE_MIB" -gt 626 ] || die "--size-mib must be > 626 (rootfs starts at 610 MiB; 16 MiB minimum)"
LEN_ROOTFS=$(( (SIZE_MIB - 610) * MIB ))

echo "== inputs =="
echo "  kernel : $KERNEL ($(stat -c%s "$KERNEL") bytes)"
echo "  rootfs : $ROOTFS ($(du -sh --apparent-size "$ROOTFS" | cut -f1) apparent)"
echo "  out    : $OUT  (${SIZE_MIB} MiB, rootfs region $((LEN_ROOTFS / MIB)) MiB)"

# ---------------------------------------------------------------- guards ----
# 1. The stock bootloader runs `bootm` from a 32-bit U-Boot, and the CPU is a
#    Cortex-A7 (ARMv7) - only a 32-bit ARM uImage can boot here.
if [ "$ALLOW_FOREIGN" -eq 0 ]; then
  python3 - "$KERNEL" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(64)
if d[:4] != b'\x27\x05\x19\x56':
    sys.exit("kernel is not a uImage (bad magic 0x27051956): the stock "
             "bootloader only understands `bootm` legacy images")
arch = d[29]
if arch != 2:
    sys.exit(f"uImage ih_arch={arch}, expected 2 (ARM). This SoC is a "
             "Cortex-A7 (ARMv7) and cannot execute AArch64.")
size = struct.unpack('>I', d[12:16])[0]
name = d[32:64].rstrip(b'\0').decode('utf-8', 'replace')
print(f"  uImage OK: ARM(32-bit), payload {size} bytes, name={name!r}")
PY
fi

# 2. The rootfs must be armhf: an arm64 userland cannot run on armv7l.
if [ "$ALLOW_FOREIGN" -eq 0 ]; then
  if [ -e "$ROOTFS/lib/ld-linux-aarch64.so.1" ] || [ -e "$ROOTFS/usr/lib/ld-linux-aarch64.so.1" ]; then
    die "rootfs is arm64 (aarch64 loader present) - it will not run on this armv7l/Cortex-A7 box"
  fi
  if [ ! -e "$ROOTFS/lib/ld-linux-armhf.so.3" ] && [ ! -e "$ROOTFS/lib/ld-linux.so.3" ]; then
    die "no armhf dynamic loader in rootfs (expected lib/ld-linux-armhf.so.3); use --allow-foreign to override"
  fi
  echo "  rootfs loader OK: $(ls "$ROOTFS"/lib/ld-linux* 2>/dev/null | head -1)"
fi

# ------------------------------------------------------------- build env ----
if [ -z "$BOOTARGS" ]; then
  BOOTARGS="$(mktemp /tmp/bootargs.XXXXXX.bin)"
  # Values copied verbatim from the live box's p2 (CRC verified); mkbootenv.py
  # recomputes the CRC32 over the whole 65532-byte payload.
  python3 "$here/mkbootenv.py" "$BOOTARGS" \
    --set "baudrate=115200" \
    --set "ethaddr=00:11:22:33:44:55" \
    --set "ipaddr=192.168.1.10" \
    --set "netmask=255.255.255.0" \
    --set "gatewayip=192.168.1.1" \
    --set "serverip=192.168.1.1" \
    --set "bootcmd=mmc read 0 0x1FFFFC0 0x7000 0xA000;bootm 0x1FFFFC0" \
    --set "bootargs_512M=mem=512M mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs_768M=mem=768M mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs_1G=mem=1G mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs_2G=mem=2G mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs_1536M=mem=1536M mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs_3840M=mem=3840M mmz=ddr,0,0,48M vmalloc=500M" \
    --set "bootargs=model=mv100 console=ttyAMA0,115200 root=/dev/mmcblk0p9 rootfstype=ext4 rootwait blkdevparts=mmcblk0:1M(boot),1M(bootargs),4M(baseparam),4M(pqparam),4M(logo),20M(kernel),64M(busybox),512M(backup),-(ubuntu)" \
    --set "bootdelay=0" \
    --set "stdin=serial" \
    --set "stdout=serial" \
    --set "stderr=serial"
  echo "  bootargs: generated from the live env (CRC-verified layout)"
else
  [ "$(stat -c%s "$BOOTARGS")" -eq 65536 ] || die "bootargs blob must be 65536 bytes"
  echo "  bootargs: $BOOTARGS (user supplied)"
fi

# ---------------------------------------------------------- write image -----
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${SIZE_MIB}M" "$OUT"

put() { # put FILE OFFSET LABEL
  local f="$1" off="$2" label="$3" sz
  sz=$(stat -c%s "$f")
  dd if="$f" of="$OUT" bs=1M seek="$((off / MIB))" conv=notrunc status=none
  printf '  %-12s offset %6d MiB  %10d bytes\n' "$label" "$((off / MIB))" "$sz"
}

echo "== writing raw regions =="
if [ "$WITH_BOOTLOADER" -eq 1 ] && [ -f "$PREBUILT/fastboot.bin" ]; then
  put "$PREBUILT/fastboot.bin" 0 "fastboot"
fi
put "$BOOTARGS" "$OFF_BOOTARGS" "bootargs"
[ -f "$PREBUILT/baseparam.img" ] && put "$PREBUILT/baseparam.img" "$OFF_BASEPARAM" "baseparam"
[ -f "$PREBUILT/pq_param.bin" ]  && put "$PREBUILT/pq_param.bin"  "$OFF_PQPARAM"  "pq_param"
[ -f "$PREBUILT/logo.img" ]      && put "$PREBUILT/logo.img"      "$OFF_LOGO"      "logo"

ksz=$(stat -c%s "$KERNEL")
[ "$ksz" -le "$KERNEL_MAX" ] || die "kernel is $ksz bytes > 20 MiB kernel partition"
put "$KERNEL" "$OFF_KERNEL" "kernel"

echo "== filesystems (mke2fs at byte offsets, no loop devices needed) =="
mkfs_at() { # mkfs_at OFFSET_MIB SIZE_MIB [rootfs_dir] [label]
  local off_mib="$1" len_mib="$2" src="${3:-}" label="${4:-fs}"
  local blocks=$(( len_mib * MIB / 4096 ))
  local args=(-q -F -t ext4 -b 4096 -E "offset=$((off_mib * MIB))")
  if [ -n "$src" ]; then
    args+=(-d "$src")
    mke2fs "${args[@]}" "$OUT" "$blocks" >/dev/null
  else
    mke2fs "${args[@]}" "$OUT" "$blocks" >/dev/null
  fi
  printf '  %-12s offset %6d MiB  %10d MiB  %s\n' \
    "$label" "$off_mib" "$len_mib" "${src:+populated from $src}"
}
mkfs_at 34 64 "" "busybox"
mkfs_at 98 512 "" "backup"
mkfs_at 610 $((SIZE_MIB - 610)) "$ROOTFS" "rootfs(p9)"

# ----------------------------------------------------------- verification ---
echo "== verification =="
python3 - "$OUT" "$OFF_KERNEL" "$OFF_BOOTARGS" "$OFF_BUSYBOX" "$OFF_BACKUP" "$OFF_ROOTFS" <<'PY'
import struct, sys, zlib
img, koff, eoff, boff, bkoff, roff = sys.argv[1], *[int(x) for x in sys.argv[2:]]
fail = []
with open(img, 'rb') as f:
    def rd(off, n):
        f.seek(off); return f.read(n)

    # kernel: uImage magic + arch + payload fits the 20 MiB window
    k = rd(koff, 64)
    if k[:4] != b'\x27\x05\x19\x56':
        fail.append("kernel uImage magic missing at 14 MiB")
    else:
        arch, psz = k[29], struct.unpack('>I', k[12:16])[0]
        name = k[32:64].rstrip(bytes([0])).decode('utf8', 'replace')
        state = 'ARM32 OK' if arch == 2 else 'WRONG ARCH'
        print(f"  kernel  : uImage arch={arch} ({state}) "
              f"payload={psz} name={name!r}")
        if arch != 2: fail.append(f"uImage arch {arch} != 2 (ARM)")
        if psz > 20 * 1024 * 1024 - 64: fail.append("kernel payload exceeds 20 MiB window")

    # env: CRC32 over the whole 65532-byte payload
    e = rd(eoff, 65536)
    stored = struct.unpack('<I', e[:4])[0]
    payload = e[4:]
    calc = zlib.crc32(payload) & 0xffffffff
    ok = stored == calc
    print(f"  bootargs: CRC stored=0x{stored:08x} calc=0x{calc:08x} {'OK' if ok else 'BROKEN'}")
    if not ok: fail.append("bootargs CRC mismatch - bootloader will ignore it")
    txt = payload.split(b'\0\0')[0].decode('utf8', 'replace')
    for need in ("bootcmd=mmc read", "root=/dev/mmcblk0p9", "blkdevparts="):
        if need not in txt:
            fail.append(f"bootargs missing {need!r}")
    boot = 'MISSING'
    if 'bootcmd=' in txt:
        boot = txt.split('bootcmd=')[1].split('\x00')[0]
    print(f"  bootcmd : {boot}")

    # ext4 superblocks: magic 0xEF53 at superblock+56
    for off, label in ((boff, "busybox"), (bkoff, "backup"), (roff, "rootfs")):
        sb = rd(off + 1024, 1024)
        magic = struct.unpack('<H', sb[56:58])[0]
        blocks = struct.unpack('<I', sb[4:8])[0] if len(sb) >= 8 else 0
        print(f"  {label:9s}: ext4 magic=0x{magic:04x} {'OK' if magic == 0xEF53 else 'MISSING'}"
              f" blocks={blocks}")
        if magic != 0xEF53: fail.append(f"{label}: no ext4 superblock")

if fail:
    print("VERIFICATION FAILED:")
    for m in fail: print("  -", m)
    sys.exit(1)
print("  all checks passed")
PY

# optional deep check of the rootfs region (sparse copy, only when affordable)
if [ "$FSCK" = always ] || { [ "$FSCK" = auto ] && [ "$((SIZE_MIB - 610))" -le 256 ]; }; then
  echo "== e2fsck on rootfs region =="
  part="$(mktemp /tmp/rootfspart.XXXXXX.img)"
  dd if="$OUT" of="$part" bs=1M skip=610 count=$((SIZE_MIB - 610)) conv=sparse status=none
  e2fsck -fn "$part" | tail -5 || true
  echo "-- top level of rootfs --"
  debugfs -R 'ls -l /' "$part" 2>/dev/null | sed -n '3,15p'
  rm -f "$part"
fi

echo "== done =="
echo "  image : $OUT ($(du -h --apparent-size "$OUT" | cut -f1) logical, $(du -h "$OUT" | cut -f1) on disk)"
echo "  flash : dd if=$OUT of=/dev/mmcblk0 bs=4M conv=fsync   (wipes the eMMC)"
