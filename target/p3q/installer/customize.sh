# Disable AVB verification in the vbmeta partition when installing.
# A stock vbmeta (eg. restored with Odin, or the one of a different firmware family) keeps hashtree
# descriptors that do not match the ROM partitions: first stage init then fails to set up dm-verity for
# /vendor ("device-mapper: verity: Hash device is too small") and the kernel panics before Android starts.
# Same as `fastboot --disable-verity --disable-verification flash vbmeta`: the device vbmeta is kept, only
# its header flags (be32 at offset 120) are set to 3 (HASHTREE_DISABLED | VERIFICATION_DISABLED).
LOG "- Adding vbmeta_disable_verification.sh"
cat > "$TMP_DIR/vbmeta_disable_verification.sh" << 'EOF'
#!/system/bin/sh
DEV=""
for d in /dev/block/bootdevice/by-name/vbmeta /dev/block/by-name/vbmeta; do
    if [ -b "$d" ]; then
        DEV="$d"
        break
    fi
done
if [ -z "$DEV" ]; then
    echo "vbmeta: partition not found"
    exit 0
fi
if [ "$(dd if="$DEV" bs=4 count=1 2> /dev/null)" != "AVB0" ]; then
    echo "vbmeta: no AVB0 header, leaving it as is"
    exit 0
fi
printf '\003' | dd of="$DEV" bs=1 seek=123 count=1 conv=notrunc 2> /dev/null || exit 1
sync
if command -v od > /dev/null 2>&1; then
    FLAGS="$(dd if="$DEV" bs=1 skip=123 count=1 2> /dev/null | od -A n -t x1 | tr -d ' \n')"
    if [ "$FLAGS" != "03" ]; then
        echo "vbmeta: write failed, flags byte is $FLAGS"
        exit 1
    fi
fi
echo "vbmeta: verification disabled"
exit 0
EOF
chmod 755 "$TMP_DIR/vbmeta_disable_verification.sh"
