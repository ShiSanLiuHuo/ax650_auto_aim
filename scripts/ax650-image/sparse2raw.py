#!/usr/bin/env python3
"""Convert an Android sparse image stored inside an Axera .axp (zip) into a raw ext4 image.

Usage:
    python3 sparse2raw.py --list <file.axp>
    python3 sparse2raw.py <file.axp> <member-name> <out.raw>

The .axp firmware package is a plain ZIP container.  The *_sparse.ext4 members
inside it use the Android "sparse image" format (magic 0xED26FF3A), which the
Linux kernel / losetup cannot mount directly.  This script streams a member out
of the ZIP and writes a raw ext4 image.

Holes (DONT_CARE chunks and zero FILL chunks) are emitted with lseek(), so on a
sparse-capable filesystem (APFS, ext4) the output occupies only the really
written payload instead of the full partition size.
"""

import argparse
import os
import struct
import sys
import zipfile

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4

HEADER_FMT = "<IHHHHIIII"
HEADER_SIZE = struct.calcsize(HEADER_FMT)  # 28
CHUNK_FMT = "<HHII"
CHUNK_SIZE = struct.calcsize(CHUNK_FMT)  # 12

READ_BLOCK = 1 << 22  # 4 MiB
ZERO_BLOCK = b"\x00" * READ_BLOCK


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024.0:
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024.0
    return f"{n:.1f}PiB"


def read_exact(stream, n, what):
    buf = stream.read(n)
    if len(buf) != n:
        raise SystemExit(f"error: truncated stream while reading {what} "
                         f"(wanted {n} bytes, got {len(buf)})")
    return buf


def peek_header(stream):
    """Read + parse the sparse header, leaving the stream right after it."""
    raw = read_exact(stream, HEADER_SIZE, "sparse header")
    magic, major, _minor, fhdr, chdr, blk, total_blks, total_chunks, csum = \
        struct.unpack(HEADER_FMT, raw)
    if magic != SPARSE_MAGIC:
        raise SystemExit(f"error: not an Android sparse image "
                         f"(magic=0x{magic:08X}, expected 0x{SPARSE_MAGIC:08X})")
    if fhdr < HEADER_SIZE:
        raise SystemExit(f"error: bogus file header size {fhdr}")
    if fhdr > HEADER_SIZE:
        read_exact(stream, fhdr - HEADER_SIZE, "extended file header")
    if chdr < CHUNK_SIZE:
        raise SystemExit(f"error: bogus chunk header size {chdr}")
    return {
        "major": major, "blk": blk, "total_blks": total_blks,
        "total_chunks": total_chunks, "file_hdr_sz": fhdr,
        "chunk_hdr_sz": chdr, "checksum": csum,
    }


def describe(axp_path):
    with zipfile.ZipFile(axp_path) as zf:
        print(f"{axp_path}")
        print(f"{'member':<44}{'zip size':>14}{'raw size':>14}  layout")
        for info in zf.infolist():
            if not info.filename.endswith(".ext4"):
                continue
            with zf.open(info) as st:
                try:
                    h = peek_header(st)
                except SystemExit as exc:
                    print(f"{info.filename:<44}{human(info.file_size):>14}"
                          f"{'?':>14}  {exc}")
                    continue
            raw = h["total_blks"] * h["blk"]
            print(f"{info.filename:<44}{human(info.file_size):>14}{human(raw):>14}"
                  f"  {h['total_chunks']} chunks, block={h['blk']}")


def convert(axp_path, member, out_path):
    with zipfile.ZipFile(axp_path) as zf:
        names = zf.namelist()
        if member not in names:
            raise SystemExit(f"error: member {member!r} not in archive.\n"
                             f"available: {', '.join(names)}")
        info = zf.getinfo(member)
        with zf.open(info) as st:
            h = peek_header(st)
            blk = h["blk"]
            total = h["total_blks"] * blk
            print(f"[sparse2raw] {member}: raw size {human(total)}, "
                  f"{h['total_chunks']} chunks, block {blk}B", file=sys.stderr)

            out = open(out_path, "wb")
            try:
                # Reserve the full logical size up front so holes read as zero.
                out.truncate(total)

                offset = 0          # absolute byte offset of the current chunk
                written = 0         # payload actually written (real disk usage)
                holes = 0
                next_report = 0

                for idx in range(h["total_chunks"]):
                    ctype, _res, csz, tsz = struct.unpack(
                        CHUNK_FMT, read_exact(st, CHUNK_SIZE, "chunk header"))
                    span = csz * blk
                    data = tsz - h["chunk_hdr_sz"]
                    if data < 0:
                        raise SystemExit(f"error: chunk {idx} has total_sz < "
                                         f"chunk_hdr_sz")
                    if ctype == CHUNK_RAW:
                        if data != span:
                            raise SystemExit(
                                f"error: RAW chunk {idx} payload {data}B != "
                                f"span {span}B")
                        out.seek(offset)
                        left = data
                        while left:
                            buf = st.read(min(left, READ_BLOCK))
                            if not buf:
                                raise SystemExit(
                                    f"error: truncated RAW chunk {idx}")
                            out.write(buf)
                            left -= len(buf)
                        written += data
                    elif ctype == CHUNK_FILL:
                        val = read_exact(st, 4, "fill value")
                        if data > 4:
                            st.seek(data - 4, os.SEEK_CUR)
                        if val == b"\x00\x00\x00\x00":
                            holes += span          # lseek hole: costs nothing
                        else:
                            out.seek(offset)
                            left = span
                            pat = val * (READ_BLOCK // 4)
                            while left:
                                n = min(left, READ_BLOCK)
                                out.write(pat[:n])
                                left -= n
                            written += span
                    elif ctype == CHUNK_DONT_CARE:
                        if data:
                            st.seek(data, os.SEEK_CUR)
                        holes += span
                    elif ctype == CHUNK_CRC32:
                        if data > 4:
                            st.seek(data, os.SEEK_CUR)
                        else:
                            read_exact(st, 4, "crc32")
                    else:
                        raise SystemExit(f"error: unknown chunk type "
                                         f"0x{ctype:04X} at index {idx}")

                    offset += span
                    if offset >= next_report:
                        pct = offset * 100.0 / total if total else 100.0
                        print(f"[sparse2raw]   {pct:5.1f}%  "
                              f"{human(offset)} / {human(total)}  "
                              f"(written {human(written)})", file=sys.stderr)
                        next_report = offset + (1 << 30)  # every 1 GiB

                if offset > total:
                    raise SystemExit("error: chunks overrun the declared size")
                out.truncate(total)
            finally:
                out.close()

    st = os.stat(out_path)
    print(f"[sparse2raw] done: {out_path}\n"
          f"[sparse2raw]   logical {human(st.st_size)}, "
          f"on-disk {human(st.st_blocks * 512)} "
          f"(holes saved {human(holes)})", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("axp", help="the .axp firmware package (a ZIP)")
    ap.add_argument("member", nargs="?", help="member to extract, e.g. soc_sparse.ext4")
    ap.add_argument("out", nargs="?", help="output raw image path")
    ap.add_argument("--list", action="store_true",
                    help="list sparse members and their sizes, then exit")
    args = ap.parse_args()

    if args.list:
        describe(args.axp)
        return
    if not args.member or not args.out:
        ap.error("member and out are required unless --list is used")
    convert(args.axp, args.member, args.out)


if __name__ == "__main__":
    main()
