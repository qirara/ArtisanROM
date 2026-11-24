#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Helper to drop the source QCC stack (QTI gps-release: com.qti.qcc + the qccsyshal system HAL).
#
#   qcc.py list <system_ext dir>
#       Prints the paths (relative to <system_ext dir>) to delete: app/priv-app folders whose APK
#       package is com.qti.qcc, the qccsyshal service binaries, init scripts, VINTF fragments and
#       the com.qti.qcc permission/sysconfig files.
#   qcc.py strip-manifest <manifest.xml> [<hal name>...]
#       Removes the <hal> entries with the given names (default: the qccsyshal ones) in place.

import os
import re
import struct
import sys
import zipfile

PACKAGE = "com.qti.qcc"
HAL_NAMES = ("vendor.qti.hardware.qccsyshal", "vendor.qti.qccsyshal_aidl")


def manifest_package(apk):
    try:
        with zipfile.ZipFile(apk) as z:
            data = z.read("AndroidManifest.xml")
    except (KeyError, zipfile.BadZipFile, OSError):
        return None
    if len(data) < 8 or struct.unpack_from("<H", data, 0)[0] != 0x0003:
        return None

    strings = []
    pos = struct.unpack_from("<H", data, 2)[0]
    while pos + 8 <= len(data):
        ctype, hsize, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == 0x0001:  # RES_STRING_POOL_TYPE
            count, _, flags, start, _ = struct.unpack_from("<IIIII", data, pos + 8)
            offsets = struct.unpack_from("<%dI" % count, data, pos + hsize)
            for off in offsets:
                p = pos + start + off
                if flags & 0x100:  # UTF-8
                    p += 2 if data[p] & 0x80 else 1
                    n = data[p]
                    p += 1
                    if n & 0x80:
                        n = ((n & 0x7f) << 8) | data[p]
                        p += 1
                    strings.append(data[p:p + n].decode("utf-8", "replace"))
                else:
                    n = struct.unpack_from("<H", data, p)[0]
                    p += 2
                    if n & 0x8000:
                        n = ((n & 0x7fff) << 16) | struct.unpack_from("<H", data, p)[0]
                        p += 2
                    strings.append(data[p:p + 2 * n].decode("utf-16-le", "replace"))
        elif ctype == 0x0102:  # RES_XML_START_ELEMENT_TYPE
            ext = pos + hsize
            _, name, attr_start, attr_size, attr_count = struct.unpack_from("<iiHHH", data, ext)
            if 0 <= name < len(strings) and strings[name] == "manifest":
                for i in range(attr_count):
                    a = ext + attr_start + i * attr_size
                    _, aname, raw, _, _, vtype, vdata = struct.unpack_from("<iiiHBBI", data, a)
                    if 0 <= aname < len(strings) and strings[aname] == "package":
                        if 0 <= raw < len(strings):
                            return strings[raw]
                        if vtype == 0x03 and vdata < len(strings):
                            return strings[vdata]
                return None
        pos += csize
    return None


def cmd_list(root):
    out = []
    for d in ("app", "priv-app"):
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            app = os.path.join(base, name)
            if not os.path.isdir(app):
                continue
            if any(f.endswith(".apk") and manifest_package(os.path.join(app, f)) == PACKAGE
                   for f in os.listdir(app)):
                out.append(os.path.join(d, name))

    for d in ("bin", "bin/hw", "etc/init", "etc/vintf/manifest",
              "etc/permissions", "etc/sysconfig", "etc/default-permissions"):
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            low = name.lower()
            if "qccsyshal" in low:
                out.append(os.path.join(d, name))
            elif d.startswith("etc/") and "qcc" in low:
                with open(path, "rb") as f:
                    if PACKAGE.encode() in f.read():
                        out.append(os.path.join(d, name))

    if out:
        print("\n".join(out))
    return 0


def cmd_strip_manifest(path, names):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    removed = 0
    for name in names:
        pattern = re.compile(r"[ \t]*<hal\b[^>]*>(?:(?!</hal>).)*?<name>\s*" + re.escape(name) +
                             r"\s*</name>.*?</hal>[ \t]*\n?", re.S)
        text, n = pattern.subn("", text)
        removed += n
    if removed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    print(removed)
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "list":
        return cmd_list(argv[2])
    if len(argv) >= 3 and argv[1] == "strip-manifest":
        return cmd_strip_manifest(argv[2], argv[3:] or HAL_NAMES)
    print("usage: qcc.py list <system_ext dir> | strip-manifest <manifest.xml> [<hal name>...]",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
