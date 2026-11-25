#!/sbin/sh
#
# Sets the flags of the device vbmeta header (be32 at offset 120) to 3, HASHTREE_DISABLED |
# VERIFICATION_DISABLED, like `fastboot --disable-verity --disable-verification` does. The rest of the
# device vbmeta is kept as is.
# A stock vbmeta (eg. restored with Odin) keeps hashtree descriptors that do not match the ROM partitions:
# first stage init fails to set up dm-verity for /vendor ("verity: Hash device is too small") and panics.
#
# Run by the ROM installer (run_program, no argument) or as the update-binary of a standalone zip
# (<api version> <ui_print fd> <zip>). Only uses sh, dd and printf, whichever implementation the
# recovery ships. Every step is logged to /tmp/recovery.log. Exit status: 0 on success (or nothing to do),
# 1 on failure.

OUTFD="$2"
LOGFILE="/tmp/recovery.log"

case "$OUTFD" in
    ''|*[!0-9]*)
        # Run by the updater (updater <api version> <ui_print fd> <zip>) with run_program: its ui_print
        # pipe is inherited, print there too
        OUTFD="$(tr "\0" "\n" < "/proc/$PPID/cmdline" 2> /dev/null | sed -n 3p 2> /dev/null)"
        ;;
esac
case "$OUTFD" in
    ''|*[!0-9]*) OUTFD="" ;;
    *) [ -p "/proc/self/fd/$OUTFD" ] || OUTFD="" ;;
esac

ui_print()
{
    if [ -n "$OUTFD" ]; then
        echo "ui_print $1" >> "/proc/self/fd/$OUTFD"
        echo "ui_print" >> "/proc/self/fd/$OUTFD"
    fi
    echo "vbmeta: $1"
    echo "vbmeta: $1" >> "$LOGFILE" 2> /dev/null
}

# Hexadecimal value of the flags byte, for the log only
flags_hex()
{
    for OD in "od" "toybox od" "busybox od"; do
        HEX="$($DD if="$DEV" bs=1 skip=123 count=1 2> /dev/null | $OD -A n -t x1 2> /dev/null | tr -d " \n" 2> /dev/null)"
        if [ -n "$HEX" ]; then
            echo "0x$HEX"
            return 0
        fi
    done
    echo "unknown"
}

DEV=""
for d in /dev/block/bootdevice/by-name/vbmeta /dev/block/by-name/vbmeta; do
    if [ -b "$d" ]; then
        DEV="$d"
        break
    fi
done
if [ -z "$DEV" ]; then
    ui_print "vbmeta partition not found, nothing to do"
    exit 0
fi

DD=""
for t in "dd" "toybox dd" "busybox dd"; do
    if [ "$($t if="$DEV" bs=4 count=1 2> /dev/null)" = "AVB0" ]; then
        DD="$t"
        break
    fi
done
if [ -z "$DD" ]; then
    ui_print "$DEV has no AVB0 header (or dd cannot read it), leaving it as is"
    exit 0
fi

# The flags byte value, a single 0x03 byte
B3=""
PRINTF=""
for t in "printf" "toybox printf" "busybox printf"; do
    B3="$($t '\003' 2> /dev/null)"
    if [ "${#B3}" = "1" ]; then
        PRINTF="$t"
        break
    fi
done
if [ -z "$PRINTF" ]; then
    ui_print "ERROR: no printf producing raw bytes"
    exit 1
fi

ui_print "Device vbmeta: $DEV, flags byte $(flags_hex) (dd: $DD)"
if [ "$($DD if="$DEV" bs=1 skip=123 count=1 2> /dev/null)" = "$B3" ]; then
    ui_print "Verification is already disabled"
    exit 0
fi

# Recovery kernels may set the partitions read-only
for t in "blockdev" "toybox blockdev" "busybox blockdev"; do
    $t --setrw "$DEV" > /dev/null 2>&1 && break
done

# Block devices are not truncated by dd, no conv=notrunc (not supported by every dd)
$PRINTF '\003' | $DD of="$DEV" bs=1 seek=123 count=1 >> "$LOGFILE" 2>&1
sync
for t in "blockdev" "toybox blockdev" "busybox blockdev"; do
    $t --flushbufs "$DEV" > /dev/null 2>&1 && break
done

if [ "$($DD if="$DEV" bs=1 skip=123 count=1 2> /dev/null)" = "$B3" ]; then
    ui_print "Verification disabled, flags byte now $(flags_hex)"
    exit 0
fi
ui_print "ERROR: could not write $DEV, flags byte still $(flags_hex)"
exit 1
