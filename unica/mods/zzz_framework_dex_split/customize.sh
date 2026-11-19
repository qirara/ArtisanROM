# The framework.jar classes.dex of the S9260 (qssi) source has no headroom left in its string
# table: the strings added to it by the mods (eg. the Google Photos one in ApplicationPackageManager)
# shift the strings at the 16-bit boundary, which their const-string instructions can then no longer
# reference when apktool assembles the dex ("Unsigned short value out of range: 65538").
# Move the patched android.app.ApplicationPackageManager to a new dex, taking its strings and methods
# with it: boot classpath jars load all of their dex files.
SKIPUNZIP=1

FRAMEWORK_DIR="$APKTOOL_DIR/system/framework/framework.jar"

if [[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" != "qssi" ]] || \
        [ ! -f "$FRAMEWORK_DIR/smali/android/app/ApplicationPackageManager.smali" ]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    return 0
fi

DEX_INDEX=1
while [ -d "$FRAMEWORK_DIR/smali_classes$((DEX_INDEX + 1))" ]; do
    DEX_INDEX=$((DEX_INDEX + 1))
done
DEX_INDEX=$((DEX_INDEX + 1))

LOG "- Moving android.app.ApplicationPackageManager to classes$DEX_INDEX.dex in /system/system/framework/framework.jar"
# Inner class files contain "$": move them without EVAL, which would expand it
mkdir -p "$FRAMEWORK_DIR/smali_classes$DEX_INDEX/android/app" || \
    ABORT "Failed to create smali_classes$DEX_INDEX in /system/system/framework/framework.jar"
find "$FRAMEWORK_DIR/smali/android/app" -maxdepth 1 -type f \
    \( -name 'ApplicationPackageManager.smali' -o -name 'ApplicationPackageManager$*.smali' \) \
    -exec mv -f -t "$FRAMEWORK_DIR/smali_classes$DEX_INDEX/android/app/" {} + || \
    ABORT "Failed to move ApplicationPackageManager to classes$DEX_INDEX.dex"

[ -f "$FRAMEWORK_DIR/smali_classes$DEX_INDEX/android/app/ApplicationPackageManager.smali" ] || \
    ABORT "Failed to move ApplicationPackageManager to classes$DEX_INDEX.dex"

unset FRAMEWORK_DIR DEX_INDEX
