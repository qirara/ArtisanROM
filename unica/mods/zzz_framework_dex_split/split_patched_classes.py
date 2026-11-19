#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Moves every class added or changed by the patches (compared with the pristine apktool decode)
# into a new smali_classesN folder, so that apktool assembles it into a new dex. The original
# dex files then only lose strings/methods/fields/types: a dex already full up to a 16-bit limit
# (eg. its string table, "Unsigned short value out of range: 65538") can no longer overflow.
# Boot classpath jars load all of their dex files, the class location does not matter.
#
# Usage: split_patched_classes.py <pristine decoded dir> <patched decoded dir>
# Prints "<new dex index> <new classes> <changed classes>".

import filecmp
import os
import re
import shutil
import sys


def smali_dirs(root):
    return sorted(d for d in os.listdir(root)
                  if (d == "smali" or re.fullmatch(r"smali_classes\d+", d))
                  and os.path.isdir(os.path.join(root, d)))


def dex_index(name):
    return 1 if name == "smali" else int(name[len("smali_classes"):])


def classes(root, folder):
    base = os.path.join(root, folder)
    for dirpath, _, filenames in os.walk(base):
        for f in filenames:
            if f.endswith(".smali"):
                path = os.path.join(dirpath, f)
                yield os.path.relpath(path, base), path


def main():
    if len(sys.argv) != 3:
        print("Usage: split_patched_classes.py <pristine decoded dir> <patched decoded dir>", file=sys.stderr)
        return 2
    pristine, patched = sys.argv[1], sys.argv[2]

    original = {}
    for folder in smali_dirs(pristine):
        for rel, path in classes(pristine, folder):
            original[rel] = path

    folders = smali_dirs(patched)
    if not folders:
        print("No smali folder in %s" % patched, file=sys.stderr)
        return 1
    new_index = max(dex_index(f) for f in folders) + 1

    to_move = []
    added = changed = 0
    for folder in folders:
        for rel, path in classes(patched, folder):
            orig = original.get(rel)
            if orig is not None and filecmp.cmp(orig, path, shallow=False):
                continue
            to_move.append((rel, path))
            if orig is None:
                added += 1
            else:
                changed += 1

    if to_move:
        target = os.path.join(patched, "smali_classes%d" % new_index)
        for rel, path in to_move:
            dst = os.path.join(target, rel)
            if os.path.exists(dst):
                print("Duplicate class %s" % rel, file=sys.stderr)
                return 1
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(path, dst)

    print("%d %d %d" % (new_index if to_move else 0, added, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
