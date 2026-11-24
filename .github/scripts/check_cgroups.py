#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that every cgroup v1 controller the ROM asks init to mount exists in the kernel.
#
# Android 16 QPR2 init aborts SetupCgroups when a controller that is not marked "Optional" fails to mount.
# The cgroup v2 system/app hierarchy is then never created, every service fails to start
# ("createProcessGroup ... No such file or directory") and init reboots with "bootstrap-apexd-failed".
#
# Usage: check_cgroups.py <work_dir>
#   <work_dir> is out/target/<codename>/work_dir, the kernel is read from <work_dir>/kernel/boot.img.

import gzip
import json
import os
import struct
import sys

# Controllers libprocessgroup mounts with a different kernel subsystem name
SUBSYS_ALIASES = {
    "sfreezer": "freezer",
}


def read_prop(path, name):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(name + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


def load_descriptors(work_dir):
    files = [os.path.join(work_dir, "system/system/etc/cgroups.json")]

    api_level = None
    for prop in ("vendor/build.prop", "vendor/default.prop", "system/system/build.prop", "product/etc/build.prop"):
        api_level = read_prop(os.path.join(work_dir, prop), "ro.product.first_api_level")
        if api_level:
            break
    if api_level:
        files.append(os.path.join(work_dir, "system/system/etc/task_profiles/cgroups_%s.json" % api_level))

    files.append(os.path.join(work_dir, "vendor/etc/cgroups.json"))

    descriptors = {}
    for path in files:
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            root = json.load(f)
        rel = os.path.relpath(path, work_dir)
        for cgroup in root.get("Cgroups", []):
            descriptors[cgroup["Controller"]] = (1, bool(cgroup.get("Optional", False)), rel)
        for cgroup in root.get("Cgroups2", {}).get("Controllers", []):
            descriptors[cgroup["Controller"]] = (2, bool(cgroup.get("Optional", False)), rel)
    return descriptors, api_level


def read_kernel(boot_img):
    with open(boot_img, "rb") as f:
        data = f.read()
    if data[:8] != b"ANDROID!":
        raise ValueError("not an Android boot image")
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    header_version = struct.unpack_from("<I", data, 40)[0]
    page_size = 4096 if header_version >= 3 else struct.unpack_from("<I", data, 36)[0]
    kernel = data[page_size:page_size + kernel_size]
    if kernel[:2] == b"\x1f\x8b":
        kernel = gzip.decompress(kernel)
    elif kernel[:4] in (b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18"):
        return None
    return kernel


def main():
    if len(sys.argv) != 2:
        print("Usage: check_cgroups.py <work_dir>", file=sys.stderr)
        return 2

    work_dir = sys.argv[1]
    descriptors, api_level = load_descriptors(work_dir)
    if not descriptors:
        print("- No cgroups.json found, skipping")
        return 0

    boot_img = os.path.join(work_dir, "kernel/boot.img")
    if not os.path.isfile(boot_img):
        print("- %s not found, skipping" % boot_img)
        return 0
    kernel = read_kernel(boot_img)
    if kernel is None:
        print("- LZ4 compressed kernel, skipping")
        return 0

    print("- ro.product.first_api_level: %s" % api_level)
    errors = 0
    for name in sorted(descriptors):
        version, optional, source = descriptors[name]
        if version != 1:
            print("  %-10s v2%s (%s)" % (name, ", optional" if optional else "", source))
            continue
        subsys = SUBSYS_ALIASES.get(name, name)
        found = (subsys.encode() + b"\x00") in kernel
        state = "ok" if found else ("missing, optional" if optional else "MISSING")
        print("  %-10s v1 %s (%s)" % (name, state, source))
        if not found and not optional:
            errors += 1

    if errors:
        print("\n! %d cgroup v1 controller(s) are not in the kernel: init will fail SetupCgroups and the device "
              "will bootloop with \"bootstrap-apexd-failed\". Remove them from the cgroups.json listed above "
              "(eg. VENDOR_DEBLOAT) or mark them \"Optional\": true." % errors)
        return 1

    print("- All the cgroup v1 controllers are in the kernel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
