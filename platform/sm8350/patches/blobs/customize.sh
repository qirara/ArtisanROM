TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

LOG_STEP_IN "- Adding OK Google Hotword Enrollment blobs"
for f in "HotwordEnrollmentOKGoogleEx4HEXAGON" "HotwordEnrollmentXGoogleEx4HEXAGON" \
        "HotwordEnrollmentOKGoogleEx5HEXAGON" "HotwordEnrollmentXGoogleEx5HEXAGON"; do
    if [ -d "$WORK_DIR/product/priv-app/$f" ]; then
        DELETE_FROM_WORK_DIR "product" "priv-app/$f"
    fi
done
ADD_TO_WORK_DIR "a73xqxx" "product" "priv-app/HotwordEnrollmentOKGoogleEx3HEXAGON" 0 0 755 "u:object_r:system_file:s0"
ADD_TO_WORK_DIR "a73xqxx" "product" "priv-app/HotwordEnrollmentXGoogleEx3HEXAGON" 0 0 755 "u:object_r:system_file:s0"
LOG_STEP_OUT

# Samsung Device Root Key (DRK, system_server DeviceRootKeyService) client libs for Keymaster 4.0 vendors:
# the source ones talk to vendor.samsung.hardware.keymint.ISehKeyMintFactory, which sm8350 does not have.
# Same JNI exports as the source library (UN1CA ships the same swap on its sm8350/sm7325 targets).
LOG_STEP_IN "- Adding Keymaster based Samsung DRK libs"
ADD_TO_WORK_DIR "r9qxxx" "system" "system/lib64/lib_nativeJni.dk.samsung.so" 0 0 644 "u:object_r:system_lib_file:s0"
DELETE_FROM_WORK_DIR "system" "system/lib64/libdk_native_keymint.so"
ADD_TO_WORK_DIR "r9qxxx" "system" "system/lib64/libdk_native_keymaster.so" 0 0 644 "u:object_r:system_lib_file:s0"
LOG_STEP_OUT

if [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/priv-app/GameDriver-SM8350/GameDriver-SM8350.apk" ]; then
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/priv-app/GameDriver-SM8350" 0 0 755 "u:object_r:system_file:s0"
fi

# Adreno GPU drivers from a newer lahaina-family (LA.UM.9.14) Android 16 vendor (a73xqxx, see adreno/.current)
if [ "$TARGET_PLATFORM_SDK_VERSION" -lt "36" ]; then
    LOG_STEP_IN "- Adding Adreno GPU blobs"
    for f in \
        "lib/egl/eglSubDriverAndroid.so" "lib/egl/libEGL_adreno.so" "lib/egl/libGLESv1_CM_adreno.so" \
        "lib/egl/libGLESv2_adreno.so" "lib/egl/libq3dtools_adreno.so" "lib/egl/libq3dtools_esx.so" \
        "lib/hw/vulkan.adreno.so" "lib/libCB.so" "lib/libadreno_utils.so" "lib/libgsl.so" \
        "lib/libllvm-glnext.so" "lib/libllvm-qcom.so"; do
        ADD_TO_WORK_DIR "$MODPATH/adreno" "vendor" "$f" 0 0 644 "u:object_r:same_process_hal_file:s0"
        ADD_TO_WORK_DIR "$MODPATH/adreno" "vendor" "${f/lib\//lib64/}" 0 0 644 "u:object_r:same_process_hal_file:s0"
    done
    LOG_STEP_OUT
fi

unset TARGET_FIRMWARE_PATH
