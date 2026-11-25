# dhkprov (services dhkprov1x/dhkprov2x, started on vendor.sys.qseecomd.enable=true) installs the DisplayPort
# HDCP 1.x/2.x keys with /system/bin/qchdcpkprov. The source one is a client of the AIDL
# vendor.samsung.hardware.security.hdcp.keyprovisioning.ISehHdcpKeyProvisioning/default service, the stock
# vendor only serves the HIDL vendor.samsung.hardware.security.hdcp.keyprovisioning@1.0 one: it crashes
# (SIGSEGV, null binder) twice on every boot. Use the stock qchdcpkprov along with its HIDL interface library.
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_SYSTEM="$FW_DIR/$TARGET_FIRMWARE_PATH/system/system"
HIDL_LIB="vendor.samsung.hardware.security.hdcp.keyprovisioning@1.0.so"

if ! grep -q -a -F "vendor.samsung.hardware.security.hdcp.keyprovisioning.ISehHdcpKeyProvisioning/default" \
        "$WORK_DIR/system/system/bin/qchdcpkprov" 2> /dev/null; then
    LOG "- The source qchdcpkprov is not an AIDL client, nothing to do"
elif ! grep -q -r -F "<name>vendor.samsung.hardware.security.hdcp.keyprovisioning</name>" \
        "$WORK_DIR/vendor/etc/vintf" 2> /dev/null; then
    LOG "- The target vendor has no HIDL HDCP key provisioning HAL, nothing to do"
elif [ ! -f "$TARGET_SYSTEM/bin/qchdcpkprov" ] || [ ! -f "$TARGET_SYSTEM/lib64/$HIDL_LIB" ]; then
    LOGW "- Target qchdcpkprov or $HIDL_LIB not found, keeping the source qchdcpkprov"
elif ! MISSING="$(python3 -I "$MODPATH/missing_libs.py" "$WORK_DIR/system/system" "$HIDL_LIB" \
        "$TARGET_SYSTEM/bin/qchdcpkprov" "$TARGET_SYSTEM/lib64/$HIDL_LIB")"; then
    LOGW "- Could not read the target qchdcpkprov dependencies, keeping the source qchdcpkprov"
elif [ "$MISSING" ]; then
    LOGW "- The target qchdcpkprov needs libraries the source system does not have ($(xargs <<< "$MISSING")), keeping the source qchdcpkprov"
else
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/bin/qchdcpkprov" 0 2000 755 "u:object_r:system_file:s0"
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/$HIDL_LIB" 0 0 644 "u:object_r:system_lib_file:s0"
fi

unset TARGET_FIRMWARE_PATH TARGET_SYSTEM HIDL_LIB MISSING
