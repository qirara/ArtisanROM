# The framework.jar dex files of the S9260 (qssi) source have no headroom left in their string
# tables: the strings the mods add (eg. the Google Photos one in ApplicationPackageManager, the
# *Hooks classes in classes6.dex) shift the strings at the 16-bit boundary, which their const-string
# instructions can then no longer reference when apktool assembles the dex
# ("Unsigned short value out of range: 65538").
# Move every class added or changed by the patches to a new dex: the original dex files then only
# lose entries compared with the stock ones. Boot classpath jars load all of their dex files, and
# _debloat already drops the stock boot image.
SKIPUNZIP=1

FRAMEWORK_DIR="$APKTOOL_DIR/system/framework/framework.jar"

if [[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" != "qssi" ]] || [ ! -d "$FRAMEWORK_DIR" ]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    unset FRAMEWORK_DIR
    return 0
fi

# Pristine apktool output of framework.jar, cached by scripts/apktool.sh before any patch
PRISTINE_DIR=""
for t in "$APK_DECODE_CACHE_DIR"/*/tree; do
    if [ -f "$t/smali/android/app/ApplicationPackageManager.smali" ]; then
        PRISTINE_DIR="$t"
        break
    fi
done
[ "$PRISTINE_DIR" ] || ABORT "Pristine framework.jar decode not found in ${APK_DECODE_CACHE_DIR//$SRC_DIR\//}"

SPLIT_RESULT="$(python3 "$MODPATH/split_patched_classes.py" "$PRISTINE_DIR" "$FRAMEWORK_DIR")" || \
    ABORT "Failed to move the patched framework.jar classes to a new dex"
read -r DEX_INDEX ADDED_CLASSES CHANGED_CLASSES <<< "$SPLIT_RESULT"

if [ "$DEX_INDEX" != "0" ]; then
    LOG "- Moving $ADDED_CLASSES added and $CHANGED_CLASSES patched classes to classes$DEX_INDEX.dex in /system/system/framework/framework.jar"
else
    LOG "\033[0;33m! No patched class found in /system/system/framework/framework.jar\033[0m"
fi

unset FRAMEWORK_DIR PRISTINE_DIR SPLIT_RESULT DEX_INDEX ADDED_CLASSES CHANGED_CLASSES t
