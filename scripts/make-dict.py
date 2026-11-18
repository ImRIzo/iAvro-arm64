#!/usr/bin/env python3
"""Convert database.db3 into avrodict.bin — a pre-sorted, compact binary
dictionary (words + suffixes) that Avro Keyboard loads at startup. The app no
longer ships or reads database.db3; it is only the source for this file.

Format (all integers little-endian):
    magic        4 bytes  b"AVD2"
    tableCount   u32
    per table:
        nameLen  u8, name (ASCII, lowercase), zero padding to a 4-byte boundary
        count    u32               number of words
        units    u32               total UTF-16 code units
        offsets  u32 * (count+1)   start of each word in `units` (last = total)
        data     u16 * units       UTF-16 code units, words sorted by code unit, de-duplicated
        padding  0/2 bytes         keeps the next table 4-byte aligned
    suffixCount  u32
    per suffix (in database row order; a later duplicate key wins, as before):
        engLen   u16, eng (UTF-8)
        bnLen    u16, bn  (UTF-8)

Usage:  python3 scripts/make-dict.py database.db3 avrodict.bin
"""
import sqlite3
import struct
import sys

TABLES = [
    "A", "AA", "B", "BH", "C", "CH", "D", "Dd", "Ddh", "Dh",
    "E", "G", "Gh", "H", "I", "II", "J", "JH", "K", "KH",
    "Khandatta", "L", "M", "N", "NGA", "NN", "NYA", "O", "OI",
    "OU", "P", "PH", "R", "RR", "RRH", "RRI", "S", "SH", "SS",
    "T", "TH", "TT", "TTH", "U", "UU", "Y", "Z",
]


def main(src: str, dst: str) -> None:
    con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    out = bytearray(b"AVD2")
    out += struct.pack("<I", len(TABLES))
    total_words = 0
    for name in TABLES:
        words = {row[0] for row in con.execute(f'SELECT Words FROM "{name}"') if row[0]}
        # Sort by UTF-16 code units (big-endian bytes compare in code-unit order).
        enc = sorted({w.encode("utf-16-be") for w in words})
        offsets, units, pos = [], bytearray(), 0
        for e in enc:
            offsets.append(pos)
            units += e.decode("utf-16-be").encode("utf-16-le")
            pos += len(e) // 2
        offsets.append(pos)
        key = name.lower().encode("ascii")
        out += struct.pack("<B", len(key)) + key
        # align the u32 block
        while len(out) % 4:
            out += b"\0"
        out += struct.pack("<II", len(enc), pos)
        out += struct.pack(f"<{len(offsets)}I", *offsets)
        out += units
        while len(out) % 4:
            out += b"\0"
        total_words += len(enc)
    suffixes = [(e, b) for e, b in con.execute("SELECT English, Bangla FROM Suffix") if e and b]
    out += struct.pack("<I", len(suffixes))
    for e, b in suffixes:
        for txt in (e, b):
            raw = txt.encode("utf-8")
            out += struct.pack("<H", len(raw)) + raw
    with open(dst, "wb") as f:
        f.write(out)
    print(f"wrote {dst}: {len(TABLES)} tables, {total_words} words, {len(suffixes)} suffixes, {len(out)} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
