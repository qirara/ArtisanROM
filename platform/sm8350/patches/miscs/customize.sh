if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    # The Android 16 Samsung software Codec2 service needs MREMAP_MAYMOVE and a few socket syscalls,
    # the One UI 7 vendor policy only allows mremap with flags == 3
    LOG_STEP_IN "- Updating Codec2 seccomp policy"
    CODEC2_POLICY="$WORK_DIR/vendor/etc/seccomp_policy/samsung.software.media.c2-base-policy"
    CODEC2_NEW_RULE="mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE"

    if [ ! -f "$CODEC2_POLICY" ]; then
        LOG "  - Codec2 seccomp policy is not present; skipping"
    else
        if grep -q -F -x "$CODEC2_NEW_RULE" "$CODEC2_POLICY"; then
            LOG "  - MREMAP_MAYMOVE is already allowed"
        elif grep -q -F -x "mremap: arg3 == 3" "$CODEC2_POLICY"; then
            LOG "  - Allowing MREMAP_MAYMOVE in ${CODEC2_POLICY//$WORK_DIR\//}"
            EVAL "sed -i 's/^mremap: arg3 == 3$/mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE/' \"$CODEC2_POLICY\""
        elif grep -q '^mremap:' "$CODEC2_POLICY"; then
            ABORT "Unsupported mremap rule in ${CODEC2_POLICY//$WORK_DIR\//}"
        else
            LOG "  - Adding the missing mremap rule to ${CODEC2_POLICY//$WORK_DIR\//}"
            EVAL "printf '%s\\n' '$CODEC2_NEW_RULE' >> \"$CODEC2_POLICY\""
        fi

        for CODEC2_SYSCALL_RULE in "setsockopt: 1" "listen: 1" "bind: 1"; do
            if ! grep -q -F -x "$CODEC2_SYSCALL_RULE" "$CODEC2_POLICY"; then
                grep -q -F -x "prctl: 1" "$CODEC2_POLICY" || \
                    ABORT "Unable to locate the Codec2 syscall insertion point"
                LOG "  - Allowing ${CODEC2_SYSCALL_RULE%%:*}"
                EVAL "sed -i '/^prctl: 1$/i$CODEC2_SYSCALL_RULE' \"$CODEC2_POLICY\""
            fi
        done

        for CODEC2_SYSCALL_RULE in "$CODEC2_NEW_RULE" "setsockopt: 1" "listen: 1" "bind: 1"; do
            grep -q -F -x "$CODEC2_SYSCALL_RULE" "$CODEC2_POLICY" || \
                ABORT "Failed to add $CODEC2_SYSCALL_RULE to ${CODEC2_POLICY//$WORK_DIR\//}"
        done
    fi
    unset CODEC2_POLICY CODEC2_NEW_RULE CODEC2_SYSCALL_RULE
    LOG_STEP_OUT
fi

# The source enables LE Audio profiles, which the Broadcom BCM4389 Bluetooth stack does not support
LOG_STEP_IN "- Setting stock Bluetooth profiles"
SET_PROP "product" "bluetooth.profile.asha.central.enabled" "true"
SET_PROP "product" "bluetooth.profile.a2dp.source.enabled" "true"
SET_PROP "product" "bluetooth.profile.avrcp.target.enabled" "true"
SET_PROP "product" "bluetooth.profile.bap.broadcast.assist.enabled" "false"
SET_PROP "product" "bluetooth.profile.bap.broadcast.source.enabled" "false"
SET_PROP "product" "bluetooth.profile.bap.unicast.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.bas.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.csip.set_coordinator.enabled" "false"
SET_PROP "product" "bluetooth.profile.gatt.enabled" "true"
SET_PROP "product" "bluetooth.profile.hap.client.enabled" "false"
SET_PROP "product" "bluetooth.profile.hfp.ag.enabled" "true"
SET_PROP "product" "bluetooth.profile.hid.device.enabled" "true"
SET_PROP "product" "bluetooth.profile.hid.host.enabled" "true"
SET_PROP "product" "bluetooth.profile.map.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.mcp.server.enabled" "false"
SET_PROP "product" "bluetooth.profile.opp.enabled" "false"
SET_PROP "product" "bluetooth.profile.pan.nap.enabled" "true"
SET_PROP "product" "bluetooth.profile.pan.panu.enabled" "true"
SET_PROP "product" "bluetooth.profile.pbap.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.sap.server.enabled" "true"
SET_PROP "product" "bluetooth.profile.ccp.server.enabled" "false"
SET_PROP "product" "bluetooth.profile.vcp.controller.enabled" "false"
LOG_STEP_OUT

# The source QCC stack (QTI gps-release: com.qti.qcc and the qccsyshal system HAL) needs a binderized
# qccvndhal, the One UI 7 lahaina vendor only ships its HIDL passthrough implementation: the system
# HAL exits and com.qti.qcc ANRs every ~16 seconds, forever.
LOG_STEP_IN "- Removing the source QCC stack"
if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
    QCC_SYSTEM_EXT="$WORK_DIR/system_ext"
else
    QCC_SYSTEM_EXT="$WORK_DIR/system/system/system_ext"
fi
QCC_FILES="$(python3 "$MODPATH/qcc.py" list "$QCC_SYSTEM_EXT")"
while IFS= read -r QCC_FILE; do
    [ "$QCC_FILE" ] || continue
    DELETE_FROM_WORK_DIR "system_ext" "$QCC_FILE"
done <<< "$QCC_FILES"
for QCC_MANIFEST in "$WORK_DIR/system/system/etc/vintf/manifest.xml" "$QCC_SYSTEM_EXT/etc/vintf/manifest.xml"; do
    [ -f "$QCC_MANIFEST" ] || continue
    if [[ "$(python3 "$MODPATH/qcc.py" strip-manifest "$QCC_MANIFEST")" != "0" ]]; then
        LOG "- Removing the qccsyshal HAL from ${QCC_MANIFEST//$WORK_DIR/}"
    fi
done
unset QCC_SYSTEM_EXT QCC_FILES QCC_FILE QCC_MANIFEST
LOG_STEP_OUT
