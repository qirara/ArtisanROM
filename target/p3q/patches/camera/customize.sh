TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

# Add target camera libs (if shipped in the target firmware)
for i in \
    "libsame_source_hdr.arcsoft.so:arcsoft" \
    "libsuperresolution_raw.arcsoft.so:arcsoft" \
    "libsuperresolutionraw_wrapper_v2.camera.samsung.so:" \
    "libuwsuperresolution.arcsoft.so:arcsoft" \
    "libuwsuperresolution_wrapper_v1.camera.samsung.so:camera.samsung"; do
    LIB="${i%%:*}"
    PUBLIC_LIBRARIES="${i#*:}"

    if [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/lib64/$LIB" ]; then
        continue
    fi

    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/$LIB" 0 0 644 "u:object_r:system_lib_file:s0"
    if [ "$PUBLIC_LIBRARIES" ] && \
            ! grep -q -x "$LIB" "$WORK_DIR/system/system/etc/public.libraries-$PUBLIC_LIBRARIES.txt" 2> /dev/null; then
        EVAL "echo \"$LIB\" >> \"$WORK_DIR/system/system/etc/public.libraries-$PUBLIC_LIBRARIES.txt\""
    fi
done

# The source camera loads its processing nodes from /system/lib64 by name (libnode-jni.so). Import the
# ones it misses for the target VENDOR_LIB_INFO features (eg. liblow_light_hdr.arcsoft.so for
# llhdr.arcsoft.v4, without it the HDR post processing fails with "load nativeNode(...) fail") from the
# target firmware, with their missing dependencies, and make the ones loaded by the app public.
CAMERA_APK="$WORK_DIR/system/system/priv-app/SamsungCamera/SamsungCamera.apk"
if [ -f "$CAMERA_APK" ] && [ -d "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/lib64" ]; then
    LOG_STEP_IN "- Adding target camera node libs"
    NODE_LIBS="$(python3 "$MODPATH/import_node_libs.py" "$WORK_DIR/system/system" "$WORK_DIR/vendor" \
        "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system" "$CAMERA_APK")"
    while read -r LIB KIND; do
        [ "$LIB" ] || continue
        if [[ "$LIB" == "MISSING" ]]; then
            LOG "- $KIND is not shipped by the source nor the target firmware"
            continue
        fi
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/lib64/$LIB" 0 0 644 "u:object_r:system_lib_file:s0"
        [[ "$KIND" == "direct" ]] || continue
        for PUBLIC_LIBRARIES in "$WORK_DIR/system/system/etc/public.libraries-"*.txt; do
            COMPANY="${PUBLIC_LIBRARIES##*/public.libraries-}"
            COMPANY="${COMPANY%.txt}"
            if [[ "$LIB" == *".$COMPANY.so" ]] && ! grep -q -x -F "$LIB" "$PUBLIC_LIBRARIES"; then
                EVAL "echo \"$LIB\" >> \"$PUBLIC_LIBRARIES\""
            fi
        done
    done <<< "$NODE_LIBS"
    LOG_STEP_OUT
fi

unset TARGET_FIRMWARE_PATH LIB PUBLIC_LIBRARIES CAMERA_APK NODE_LIBS KIND COMPANY
