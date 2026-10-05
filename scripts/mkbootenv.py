#!/usr/bin/env python3
"""Build or decode a HiSilicon/U-Boot environment blob for the EC6100V9C.

The stock bootloader reads its environment from eMMC partition 2
(blkdevparts: 1M(boot),1M(bootargs),...) at byte offset 1 MiB (sector 0x800),
size 64 KiB (0x80 sectors).

Blob layout (verified against the live box):

    offset 0 : CRC32, little endian, over the whole 65532-byte payload
    offset 4 : payload = NUL-separated "key=value" pairs, then NUL, zero padded

Verification against /dev/mmcblk0p2 of a running EC6100V9C:

    stored            = 0x45c68301
    crc32(payload[:])  = 0x45c68301   <-- MATCH

Usage:
    mkbootenv.py OUT.bin --set k=v [--set k=v ...] [--input FILE|-]
    mkbootenv.py BLOB.bin --print
"""
import argparse
import struct
import sys
import zlib

ENV_SIZE = 65536          # 0x80 sectors * 512 B, from the blkdevparts layout
HEADER = 4                # CRC32 field


def read_pairs(stream):
    pairs = []
    for line in stream:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        pairs.append((k, v))
    return pairs


def build(pairs, size=ENV_SIZE):
    payload = bytearray()
    for k, v in pairs:
        payload += k.encode() + b"=" + v.encode() + b"\x00"
    if len(payload) + HEADER > size:
        sys.exit(f"ERROR: environment too large: {len(payload) + HEADER} > {size}")
    data = payload + bytearray(size - HEADER - len(payload))
    crc = zlib.crc32(bytes(data)) & 0xFFFFFFFF
    return struct.pack("<I", crc) + data


def decode(blob):
    stored = struct.unpack("<I", blob[:HEADER])[0]
    payload = blob[HEADER:]
    calc = zlib.crc32(payload) & 0xffffffff
    end = payload.find(b"\x00\x00")
    text = payload[:end if end >= 0 else None].decode("utf-8", "replace")
    return stored, calc, text


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target",
                    help="output blob path (or existing blob path with --print)")
    ap.add_argument("--input", metavar="FILE",
                    help="file with one key=value per line ('-' = stdin)")
    ap.add_argument("--set", action="append", default=[], metavar="K=V",
                    help="set/override a variable (repeatable)")
    ap.add_argument("--print", dest="do_print", action="store_true",
                    help="decode an existing blob instead of building one")
    a = ap.parse_args()

    if a.do_print:
        blob = open(a.target, "rb").read()
        stored, calc, text = decode(blob)
        print(f"stored CRC = 0x{stored:08x}\n"
              f"calc   CRC = 0x{calc:08x}\n"
              f"valid      = {stored == calc}\n{text}")
        return

    pairs = []
    if a.input == "-":
        pairs = read_pairs(sys.stdin)
    elif a.input:
        with open(a.input) as fh:
            pairs = read_pairs(fh)

    merged = dict(pairs)                      # later --set wins
    for item in a.set:
        k, v = item.split("=", 1)
        merged[k] = v

    blob = build(list(merged.items()))
    with open(a.target, "wb") as fh:
        fh.write(blob)
    stored, calc, _ = decode(blob)
    state = "valid" if stored == calc else "BROKEN"
    print(f"wrote {a.target}: {len(blob)} bytes, {len(merged)} vars, "
          f"CRC 0x{calc:08x} ({state})")


if __name__ == "__main__":
    main()
