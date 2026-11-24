#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Helper for the netbpfload kernel version compat patch (see customize.sh).
#
#   netbpfload_kver.py extract <apex/capex> <out dir>
#       Writes <out dir>/original.apex (the inner APEX for a compressed one) and
#       <out dir>/apex_payload.img, <out dir>/apex_manifest.pb.
#   netbpfload_kver.py patch <apex_payload.img>
#       Skips the "Android 25Q4 requires kernel 5.10." check in bin/netbpfload, in place.
#       Exit code 0: patched, 3: the payload has no such check (nothing to do),
#       4: already patched, 1: error.
#   netbpfload_kver.py repack <original.apex> <apex_payload.img> <apex_pubkey> <out.apex>
#       Writes an unsigned APEX with the new payload/public key (stored), without the old signature.
#   netbpfload_kver.py verify <signed.apex>
#       Checks the final APEX: page aligned stored payload with an AVB footer, matching
#       apex_pubkey, netbpfload check skipped.

import io
import os
import sys
import zipfile

CHECK_MSG = b"Android 25Q4 requires kernel 5.10.\x00"

# NetBpfLoad doLoad():
#   if (isAtLeast25Q4 && !isAtLeastKernelVersion(5, 10, 0)) { ALOGE(...); return 7; }
# compiled as
#   cmp  w8, #0x284          ; w8 = kernelVersion() >> 17, 0x284 = KVER(5, 10, 0) >> 17 - 1
#   b.hi <past the error>    ; kernel >= 5.10
#   adrp x8, <isAtLeast25Q4>
#   ldrb w8, [x8, #...]
#   tbz  w8, #0, <past the error>
# The conditional "b.hi" becomes an unconditional "b" to the same address.
CMP_W8_0X284 = bytes.fromhex("1f110a71")

# etc/netbpfload.35rc (the one init picks on API 36): a failing netbpfload reboots the device
# ("bpfloader-failed") before adbd starts, leaving nothing to debug with. Comment it out (same
# length, in place): if netbpfload still fails on this kernel the boot stops instead, with adb.
REBOOT_ON_FAILURE = b"\n    reboot_on_failure reboot,bpfloader-failed\n"
REBOOT_ON_FAILURE_OFF = b"\n#   reboot_on_failure reboot,bpfloader-failed\n"


def b_hi_to_b(insn):
    v = int.from_bytes(insn, "little")
    if (v & 0xff00001f) != 0x54000008:  # b.hi <imm19>
        return None
    imm19 = (v >> 5) & 0x7ffff
    if imm19 & 0x40000:
        return None  # backwards, not ours
    return (0x14000000 | imm19).to_bytes(4, "little")  # b <imm26>, same offset


def find_patch_sites(data, patched=False):
    sites = []
    i = data.find(CMP_W8_0X284)
    while i != -1:
        if i % 4 == 0:
            insn = data[i + 4:i + 8]
            if patched:
                v = int.from_bytes(insn, "little")
                new = insn if (v & 0xfc000000) == 0x14000000 and (v & 0x03ffffff) < 0x40000 else None
            else:
                new = b_hi_to_b(insn)
            # followed by "adrp x8" + "ldrb w8, [x8, ...]" + "tbz w8, #0, ..."
            adrp = int.from_bytes(data[i + 8:i + 12], "little")
            ldrb = int.from_bytes(data[i + 12:i + 16], "little")
            tbz = int.from_bytes(data[i + 16:i + 20], "little")
            if new and (adrp & 0x9f00001f) == 0x90000008 and (ldrb & 0xffc003ff) == 0x39400108 and \
                    (tbz & 0xfff8001f) == 0x36000008:
                sites.append((i + 4, new))
        i = data.find(CMP_W8_0X284, i + 1)
    return sites


def cmd_extract(apex, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(apex) as z:
        if "original_apex" in z.namelist():
            inner = z.read("original_apex")
        else:
            with open(apex, "rb") as f:
                inner = f.read()
    with open(os.path.join(out_dir, "original.apex"), "wb") as f:
        f.write(inner)
    with zipfile.ZipFile(io.BytesIO(inner)) as z:
        for name in ("apex_payload.img", "apex_manifest.pb"):
            with open(os.path.join(out_dir, name), "wb") as f:
                f.write(z.read(name))
    return 0


def cmd_patch(payload):
    with open(payload, "rb") as f:
        data = bytearray(f.read())
    if CHECK_MSG not in data:
        print("No \"Android 25Q4 requires kernel 5.10.\" check in %s" % payload)
        return 3
    sites = find_patch_sites(data)
    if not sites and len(find_patch_sites(data, patched=True)) == 1:
        print("The netbpfload 25Q4 kernel check is already skipped in %s" % payload)
        return 4
    if len(sites) != 1:
        print("Expected exactly one netbpfload 25Q4 kernel check, found %d" % len(sites), file=sys.stderr)
        return 1
    off, new = sites[0]
    print("Patching b.hi -> b at payload offset %#x (%s -> %s)" % (off, data[off:off + 4].hex(), new.hex()))
    data[off:off + 4] = new
    with open(payload, "r+b") as f:
        f.seek(off)
        f.write(new)
        if data.count(REBOOT_ON_FAILURE) == 1:
            rc_off = data.find(REBOOT_ON_FAILURE)
            print("Commenting out \"reboot_on_failure reboot,bpfloader-failed\" at payload offset %#x" % rc_off)
            f.seek(rc_off)
            f.write(REBOOT_ON_FAILURE_OFF)
        else:
            print("\"reboot_on_failure reboot,bpfloader-failed\" found %d times, left as is" %
                  data.count(REBOOT_ON_FAILURE))
    return 0


def cmd_repack(original, payload, pubkey, out):
    with zipfile.ZipFile(original) as zin, zipfile.ZipFile(out, "w") as zout:
        for info in zin.infolist():
            name = info.filename
            if name.startswith("META-INF/") or name == "stamp-cert-sha256":
                continue
            new = zipfile.ZipInfo(name, date_time=info.date_time)
            new.external_attr = info.external_attr
            if name == "apex_payload.img":
                new.compress_type = zipfile.ZIP_STORED
                with open(payload, "rb") as f:
                    zout.writestr(new, f.read())
            elif name == "apex_pubkey":
                new.compress_type = zipfile.ZIP_STORED
                with open(pubkey, "rb") as f:
                    zout.writestr(new, f.read())
            else:
                new.compress_type = info.compress_type
                zout.writestr(new, zin.read(name))
    return 0


def cmd_verify(apex):
    import struct
    with zipfile.ZipFile(apex) as z:
        info = z.getinfo("apex_payload.img")
        if info.compress_type != zipfile.ZIP_STORED:
            print("apex_payload.img is compressed", file=sys.stderr)
            return 1
        with open(apex, "rb") as f:
            f.seek(info.header_offset)
            hdr = f.read(30)
            name_len, extra_len = struct.unpack_from("<HH", hdr, 26)
            data_off = info.header_offset + 30 + name_len + extra_len
        if data_off % 4096:
            print("apex_payload.img is not page aligned (%d)" % data_off, file=sys.stderr)
            return 1
        payload = z.read("apex_payload.img")
        pubkey = z.read("apex_pubkey")
    if payload[-64:-60] != b"AVBf":
        print("apex_payload.img has no AVB footer", file=sys.stderr)
        return 1
    vbmeta_off, vbmeta_size = struct.unpack_from(">QQ", payload, len(payload) - 64 + 20)
    vbmeta = payload[vbmeta_off:vbmeta_off + vbmeta_size]
    auth_size, aux_size = struct.unpack_from(">QQ", vbmeta, 12)
    pk_off, pk_size = struct.unpack_from(">QQ", vbmeta, 64)
    aux = vbmeta[256 + auth_size:256 + auth_size + aux_size]
    if aux[pk_off:pk_off + pk_size] != pubkey:
        print("apex_pubkey does not match the AVB key of apex_payload.img", file=sys.stderr)
        return 1
    if CHECK_MSG in payload and len(find_patch_sites(payload, patched=True)) != 1:
        print("netbpfload 25Q4 kernel check is not skipped", file=sys.stderr)
        return 1
    print("%s: payload at %#x, AVB signed, apex_pubkey matches, netbpfload check skipped" %
          (os.path.basename(apex), data_off))
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "extract":
        return cmd_extract(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "patch":
        return cmd_patch(argv[2])
    if len(argv) == 6 and argv[1] == "repack":
        return cmd_repack(*argv[2:6])
    if len(argv) == 3 and argv[1] == "verify":
        return cmd_verify(argv[2])
    print(__doc__ or "usage: see the header of this file", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
