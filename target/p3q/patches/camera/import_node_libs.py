#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The camera app loads its processing node libraries from /system/lib64 by name (libnode-jni.so,
# eg. liblow_light_hdr.arcsoft.so for llhdr.arcsoft.v4). Lists the ones the source system does not
# ship but the target firmware does, with their missing dependencies.
#
# Usage: import_node_libs.py <work system root> <work vendor root> <target system root> <camera apk>
# Output, one per line:
#   <lib> direct   library loaded by the camera app, to import and to make public
#   <lib> dep      dependency of an imported library, to import
#   MISSING <lib>  library loaded by the camera app that neither the source nor the target ships

import os
import re
import struct
import sys
import zipfile

NODE_JNI = "lib/arm64-v8a/libnode-jni.so"


def needed(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] != 2:
        return []
    phoff = struct.unpack_from("<Q", d, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
    loads, dyn = [], None
    for i in range(phnum):
        p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dyn = (p_offset, p_filesz)
    if not dyn:
        return []

    def va2off(va):
        for vaddr, off, size in loads:
            if vaddr <= va < vaddr + size:
                return off + va - vaddr
        return None

    strtab, names = None, []
    for i in range(dyn[1] // 16):
        tag, val = struct.unpack_from("<qQ", d, dyn[0] + i * 16)
        if tag == 0:
            break
        if tag == 5:
            strtab = va2off(val)
        elif tag == 1:
            names.append(val)
    if strtab is None:
        return []
    return [d[strtab + n:d.index(b"\0", strtab + n)].decode() for n in names]


def present(root, lib):
    path = os.path.join(root, "lib64", lib)
    return os.path.islink(path) or os.path.isfile(path)


def main(argv):
    if len(argv) != 5:
        print(__doc__ or "usage: import_node_libs.py <work system> <work vendor> <target system> <camera apk>",
              file=sys.stderr)
        return 2
    work, vendor, target, apk = argv[1:]

    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        if NODE_JNI not in names:
            return 0
        jni = z.read(NODE_JNI)
    bundled = set(os.path.basename(n) for n in names if n.startswith("lib/arm64-v8a/"))
    loaded = sorted(set(m.decode() for m in re.findall(rb"(?<=\x00)lib[A-Za-z0-9_.\-]+\.so(?=\x00)", jni))
                    - bundled)

    out, queue, seen = [], [], set()
    for lib in loaded:
        if present(work, lib) or present(vendor, lib):
            continue
        if os.path.isfile(os.path.join(target, "lib64", lib)):
            out.append((lib, "direct"))
            queue.append(lib)
            seen.add(lib)
        else:
            out.append(("MISSING", lib))

    while queue:
        lib = queue.pop(0)
        for dep in needed(os.path.join(target, "lib64", lib)):
            if dep in seen or present(work, dep) or present(vendor, dep):
                continue
            seen.add(dep)
            if os.path.isfile(os.path.join(target, "lib64", dep)):
                out.append((dep, "dep"))
                queue.append(dep)

    for a, b in out:
        print(a, b)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
