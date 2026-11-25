#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the shared libraries (DT_NEEDED) of the given ELF files that are neither in
# <system root>/lib64 (/lib for 32-bit ELFs) nor in the comma separated <provided libs> list.
#
# Usage: missing_libs.py <system root> <provided libs> <elf>...

import os
import struct
import sys


def needed(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] not in (1, 2) or d[5] != 1:
        raise ValueError(path + ": not a little endian ELF file")
    is64 = d[4] == 2
    if is64:
        phoff = struct.unpack_from("<Q", d, 0x20)[0]
        phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
    else:
        phoff = struct.unpack_from("<I", d, 0x1C)[0]
        phentsize, phnum = struct.unpack_from("<HH", d, 0x2A)

    loads, dyn = [], None
    for i in range(phnum):
        off = phoff + i * phentsize
        if is64:
            p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIQQQQ", d, off)
        else:
            p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIIII", d, off)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dyn = (p_offset, p_filesz)
    if not dyn:
        return is64, []

    def va2off(va):
        for vaddr, off, size in loads:
            if vaddr <= va < vaddr + size:
                return off + va - vaddr
        return None

    entsize, fmt = (16, "<qQ") if is64 else (8, "<iI")
    strtab, names = None, []
    for i in range(dyn[1] // entsize):
        tag, val = struct.unpack_from(fmt, d, dyn[0] + i * entsize)
        if tag == 0:
            break
        if tag == 5:
            strtab = va2off(val)
        elif tag == 1:
            names.append(val)
    if strtab is None:
        raise ValueError(path + ": no string table")
    return is64, [d[strtab + n:d.index(b"\0", strtab + n)].decode() for n in names]


def main(argv):
    if len(argv) < 4:
        print("usage: missing_libs.py <system root> <provided libs> <elf>...", file=sys.stderr)
        return 2
    system, provided, elfs = argv[1], set(filter(None, argv[2].split(","))), argv[3:]

    missing = []
    for elf in elfs:
        try:
            is64, libs = needed(elf)
        except (OSError, ValueError, struct.error) as e:
            print(e, file=sys.stderr)
            return 1
        libdir = os.path.join(system, "lib64" if is64 else "lib")
        for lib in libs:
            path = os.path.join(libdir, lib)
            if lib in provided or os.path.isfile(path) or os.path.islink(path):
                continue
            if lib not in missing:
                missing.append(lib)

    for lib in missing:
        print(lib)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
