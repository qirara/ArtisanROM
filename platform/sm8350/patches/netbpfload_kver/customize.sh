# Android 16 QPR2 (25Q4) netbpfload compatibility for 5.4 kernels
#
# The 25Q4 Tethering module netbpfload refuses to run on kernels older than 5.10:
#   NetBpfLoad: Android 25Q4 requires kernel 5.10.
# and init reboots with "bpfloader-failed" (reboot_on_failure in its netbpfload.35rc) as soon as
# /data is mounted, before the boot animation.
#
# This module version still supports 5.4 on 25Q2/25Q3 platforms, and its isAtLeast25Q4 flag only
# gates this check: on 5.4 it then loads the same $5_4 netd stats, 5_4/opt54 offload, 4_19 bind and
# 4_14 inet_create program variants. The maps that need 5.10 (ringbufs, sk_storage) are not used by
# the Java/native connectivity code.
# Skip the check, re-sign the payload with the AVB test key and the container with the platform key
# (like the bluetooth patch) and ship the APEX uncompressed. Google signed module updates can not
# replace it anymore (public key mismatch), which also keeps a newer module from bringing it back.
# The "reboot_on_failure reboot,bpfloader-failed" line of netbpfload.35rc is commented out too: if
# loading still fails on this kernel, the boot stops with adb available instead of looping.

CAPEX="com.google.android.tethering_compressed.apex"
APEX="com.google.android.tethering.apex"
APEX_DIR="$WORK_DIR/system/system/apex"

if [ -d "$TMP_DIR" ]; then
    EVAL "rm -rf \"$TMP_DIR\""
fi
EVAL "mkdir -p \"$TMP_DIR\""

# [
CLEANUP()
{
    rm -rf "$TMP_DIR"
    unset CAPEX APEX APEX_DIR SOURCE_APEX KERNEL_VERSION KEY_NAME SALT CERT_PREFIX RESULT
    unset -f CLEANUP
}
# ]

KERNEL_VERSION=""
if [ -f "$WORK_DIR/kernel/boot.img" ] && \
        unpack_bootimg --boot_img "$WORK_DIR/kernel/boot.img" --out "$TMP_DIR/boot" &> /dev/null; then
    if [[ "$(READ_BYTES_AT "$TMP_DIR/boot/kernel" "0" "2")" == "8b1f" ]]; then
        gzip -dc "$TMP_DIR/boot/kernel" > "$TMP_DIR/kernel" 2> /dev/null || true
    else
        mv -f "$TMP_DIR/boot/kernel" "$TMP_DIR/kernel"
    fi
    KERNEL_VERSION="$(grep -a -o -m 1 "Linux version [0-9]*\.[0-9]*" "$TMP_DIR/kernel" | awk '{print $3}')"
    rm -rf "$TMP_DIR/boot" "$TMP_DIR/kernel"
fi

if [ "$KERNEL_VERSION" ] && { [ "${KERNEL_VERSION%%.*}" -gt "5" ] || \
        { [[ "${KERNEL_VERSION%%.*}" == "5" ]] && [ "${KERNEL_VERSION#*.}" -ge "10" ]; }; }; then
    LOG "- Kernel $KERNEL_VERSION is supported by netbpfload, nothing to do"
    CLEANUP
    return 0
fi

if [ -f "$APEX_DIR/$CAPEX" ]; then
    SOURCE_APEX="$CAPEX"
elif [ -f "$APEX_DIR/$APEX" ]; then
    SOURCE_APEX="$APEX"
else
    LOG "\033[0;33m! Tethering APEX not found, nothing to do\033[0m"
    CLEANUP
    return 0
fi

LOG_STEP_IN "- Patching netbpfload in /system/apex/$SOURCE_APEX (kernel ${KERNEL_VERSION:-unknown})"

EVAL "python3 \"$MODPATH/netbpfload_kver.py\" extract \"$APEX_DIR/$SOURCE_APEX\" \"$TMP_DIR/apex\"" || exit 1

RESULT=0
python3 "$MODPATH/netbpfload_kver.py" patch "$TMP_DIR/apex/apex_payload.img" || RESULT=$?
if [[ "$RESULT" == "3" ]] || [[ "$RESULT" == "4" ]]; then
    LOG "- netbpfload has no 25Q4 kernel check to skip, nothing to do"
    LOG_STEP_OUT
    CLEANUP
    return 0
elif [[ "$RESULT" != "0" ]]; then
    ABORT "Failed to patch netbpfload, the device would bootloop with \"bpfloader-failed\""
fi

LOG "- Signing apex_payload.img with AVB"
KEY_NAME="$(avbtool info_image --image "$TMP_DIR/apex/apex_payload.img" 2> /dev/null | \
    sed -n "s/^ *Prop: apex.key -> '\(.*\)'$/\1/p" | head -n 1)"
[ "$KEY_NAME" ] || KEY_NAME="com.android.tethering"
# https://android.googlesource.com/platform/system/apex/+/refs/tags/android-16.0.0_r4/apexer/apexer.py#689
SALT="$(sha256sum "$TMP_DIR/apex/apex_manifest.pb" | cut -d " " -f 1)"
EVAL "avbtool erase_footer --image \"$TMP_DIR/apex/apex_payload.img\"" || exit 1
EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm \"SHA256_RSA4096\" --hash_algorithm \"sha256\" --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:$KEY_NAME\" --salt \"$SALT\" --image \"$TMP_DIR/apex/apex_payload.img\"" || exit 1
EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$TMP_DIR/apex/apex_pubkey\"" || exit 1

LOG "- Building /system/apex/$APEX"
EVAL "python3 \"$MODPATH/netbpfload_kver.py\" repack \"$TMP_DIR/apex/original.apex\" \"$TMP_DIR/apex/apex_payload.img\" \"$TMP_DIR/apex/apex_pubkey\" \"$TMP_DIR/unsigned.apex\"" || exit 1
rm -rf "$TMP_DIR/apex"

CERT_PREFIX="aosp"
if $ROM_IS_OFFICIAL; then
    CERT_PREFIX="artisanrom"
fi
mkdir -p "$TMP_DIR/stage/system/system/apex"
# https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/apex_utils.py#394
EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$TMP_DIR/unsigned.apex\" \"$TMP_DIR/stage/system/system/apex/$APEX\"" || exit 1
rm -f "$TMP_DIR/unsigned.apex"

if ! python3 "$MODPATH/netbpfload_kver.py" verify "$TMP_DIR/stage/system/system/apex/$APEX"; then
    ABORT "The rebuilt $APEX is not valid"
fi

DELETE_FROM_WORK_DIR "system" "system/apex/$SOURCE_APEX"
ADD_TO_WORK_DIR "$TMP_DIR/stage" "system" "system/apex/$APEX" 0 0 644 "u:object_r:system_file:s0" || exit 1

LOG_STEP_OUT

CLEANUP
