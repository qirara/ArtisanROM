# Odin package that disables the vbmeta verification, shipped in the zip root as vbmeta_disabled.tar.
# The Samsung p3q recovery kernels refuse to write the vbmeta partition, when the device vbmeta still has
# verification enabled the installer (root/vbmeta_disable_verification.sh) copies it to /sdcard to flash
# with Odin.
# Odin rejects the stock vbmeta.img once modified (its Samsung signature no longer matches): use an
# unsigned vbmeta with the stock descriptors and HASHTREE_DISABLED | VERIFICATION_DISABLED, in a POSIX tar.
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
STOCK_VBMETA="$FW_DIR/$TARGET_FIRMWARE_PATH/avb/vbmeta.img"

if [ -f "$STOCK_VBMETA" ]; then
    LOG "- Creating vbmeta_disabled.tar"
    ODIN_TMP="$(mktemp -d)"
    EVAL "avbtool make_vbmeta_image --flags 3 --padding_size 4096 --include_descriptors_from_image \"$STOCK_VBMETA\" --output \"$ODIN_TMP/vbmeta.img\"" || exit 1
    VBMETA_INFO="$(avbtool info_image --image "$ODIN_TMP/vbmeta.img" 2>&1)"
    if ! grep -q "^Algorithm: *NONE$" <<< "$VBMETA_INFO" || ! grep -q "^Flags: *3$" <<< "$VBMETA_INFO"; then
        ABORT "Unexpected vbmeta_disabled.tar vbmeta.img:\n\n$VBMETA_INFO"
    fi
    while IFS= read -r LINE; do
        LOG "  $LINE"
    done < <(grep -E "^(Auxiliary Block|Algorithm|Flags|Rollback Index):|Partition Name:" <<< "$VBMETA_INFO")
    EVAL "tar --format=ustar --owner=0 --group=0 --numeric-owner --mode=0644 --mtime=@0 -cf \"$TMP_DIR/vbmeta_disabled.tar\" -C \"$ODIN_TMP\" vbmeta.img" || exit 1
    rm -rf "$ODIN_TMP"
else
    LOGW "No vbmeta.img in the target firmware, vbmeta_disabled.tar is not created"
fi

unset TARGET_FIRMWARE_PATH STOCK_VBMETA ODIN_TMP VBMETA_INFO LINE
