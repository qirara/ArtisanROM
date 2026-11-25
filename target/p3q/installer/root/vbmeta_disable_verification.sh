#!/sbin/sh
#
# Sets the flags of the device vbmeta header (be32 at offset 120) to 3, HASHTREE_DISABLED |
# VERIFICATION_DISABLED, like `fastboot --disable-verity --disable-verification` does. The rest of the
# device vbmeta is kept as is.
# A stock vbmeta (eg. restored with Odin) keeps hashtree descriptors that do not match the ROM partitions:
# first stage init fails to set up dm-verity for /vendor ("verity: Hash device is too small") and panics.
#
# 1. Write the flags byte through the vbmeta partition.
# 2. Samsung recovery kernels can refuse to open vbmeta for writing ("Read-only file system"): write the
#    same byte through the whole disk, at the partition offset, once the data there is checked to be the
#    vbmeta partition.
# 3. Otherwise copy the vbmeta_disabled.tar the ROM zip ships (extracted to /tmp by the installer) to
#    /sdcard, to flash with Odin.
#
# Run by the ROM installer (run_program, no argument) or as the update-binary of a standalone zip
# (<api version> <ui_print fd> <zip>). Only uses sh and the dd/printf/blockdev/readlink/md5sum the
# recovery ships (toolbox, toybox or busybox). Every step is logged to /tmp/recovery.log.
# Exit status: 0 when verification is disabled (or there is nothing to do), 1 otherwise.

OUTFD="$2"
LOGFILE="/tmp/recovery.log"
ODIN_DIR="/sdcard"
ODIN_TAR="/tmp/vbmeta_disabled.tar"

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

# The installers retry with another shell when run_program fails: run once per updater process
if [ -z "$2" ] && [ -n "$OUTFD" ]; then
    MARKER="/tmp/vbmeta_disable_verification.$PPID"
    [ -f "$MARKER" ] && exit 1
    : > "$MARKER" 2> /dev/null
fi

ui_print()
{
    if [ -n "$OUTFD" ]; then
        echo "ui_print $1" >> "/proc/self/fd/$OUTFD"
        echo "ui_print" >> "/proc/self/fd/$OUTFD"
    fi
    echo "vbmeta: $1"
    echo "vbmeta: $1" >> "$LOGFILE" 2> /dev/null
}

log()
{
    echo "vbmeta: $1" >> "$LOGFILE" 2> /dev/null
}

# First implementation of a tool that runs: TOOL="$(find_tool <name> <test arguments>)"
find_tool()
{
    for t in "$1" "toybox $1" "busybox $1"; do
        if $t $2 > /dev/null 2>&1; then
            echo "$t"
            return 0
        fi
    done
    return 1
}

# Byte at the given offset of a device or file (NUL bytes read as empty)
read_byte()
{
    { R="$($DD if="$1" bs=1 skip="$2" count=1 2> /dev/null)"; } 2> /dev/null
    echo "$R"
}

# Hexadecimal value of the vbmeta flags byte, for the messages only
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

flush()
{
    sync
    for f in "$@"; do
        [ -n "$BLOCKDEV" ] && $BLOCKDEV --flushbufs "$f" > /dev/null 2>&1
    done
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

BLOCKDEV="$(find_tool blockdev "--getro $DEV")"

ui_print "Device vbmeta: $DEV, flags byte $(flags_hex)"
if [ "$(read_byte "$DEV" 123)" = "$B3" ]; then
    ui_print "Verification is already disabled"
    exit 0
fi

# 1. Through the vbmeta partition (block devices are not truncated by dd, no conv=notrunc: not supported
#    by every dd)
[ -n "$BLOCKDEV" ] && $BLOCKDEV --setrw "$DEV" > /dev/null 2>&1
$PRINTF '\003' | $DD of="$DEV" bs=1 seek=123 count=1 >> "$LOGFILE" 2>&1
flush "$DEV"
if [ "$(read_byte "$DEV" 123)" = "$B3" ]; then
    ui_print "Verification disabled, flags byte now $(flags_hex)"
    exit 0
fi
ui_print "Cannot write the vbmeta partition, trying through the whole disk"

# 2. Through the whole disk, at the partition offset
READLINK="$(find_tool readlink "-f /")"
MD5SUM="$(find_tool md5sum "/proc/self/cmdline")"
PART=""
DISK=""
START=""
if [ -n "$READLINK" ] && [ -n "$MD5SUM" ]; then
    PART="$($READLINK -f "$DEV" 2> /dev/null)"
    SYSPART="/sys/class/block/${PART##*/}"
    if [ -f "$SYSPART/partition" ] && [ -f "$SYSPART/start" ]; then
        START="$(cat "$SYSPART/start" 2> /dev/null)"
        SYSDISK="$($READLINK -f "$SYSPART/.." 2> /dev/null)"
        DISK="/dev/block/${SYSDISK##*/}"
    fi
fi
case "$START" in
    ''|*[!0-9]*) START="" ;;
esac
if [ -n "$START" ] && [ -b "$DISK" ] && [ "$DISK" != "$PART" ]; then
    log "partition $PART starts at sector $START of $DISK"
    # No shell arithmetic on offsets (32-bit in mksh): the first 512-byte sector of the partition is
    # read and written back with skip/seek in sectors
    PART_HEAD="$($DD if="$DEV" bs=512 count=8 2> /dev/null | $MD5SUM 2> /dev/null)"
    DISK_HEAD="$($DD if="$DISK" bs=512 skip="$START" count=8 2> /dev/null | $MD5SUM 2> /dev/null)"
    SECTOR="/tmp/vbmeta_sector.bin"
    rm -f "$SECTOR" "$SECTOR.new"
    $DD if="$DISK" of="$SECTOR" bs=512 skip="$START" count=1 > /dev/null 2>&1
    if [ "$($DD if="$SECTOR" bs=4 count=1 2> /dev/null)" = "AVB0" ] && \
            [ -n "$PART_HEAD" ] && [ "$PART_HEAD" = "$DISK_HEAD" ]; then
        {
            $DD if="$SECTOR" bs=123 count=1 2> /dev/null
            $PRINTF '\003'
            $DD if="$SECTOR" bs=124 skip=1 2> /dev/null
        } > "$SECTOR.new"
        if [ "$(wc -c < "$SECTOR.new" 2> /dev/null)" -eq 512 ] 2> /dev/null && \
                [ "$(read_byte "$SECTOR.new" 123)" = "$B3" ]; then
            [ -n "$BLOCKDEV" ] && $BLOCKDEV --setrw "$DISK" > /dev/null 2>&1
            $DD if="$SECTOR.new" of="$DISK" bs=512 seek="$START" count=1 >> "$LOGFILE" 2>&1
            flush "$DISK" "$DEV"
            if [ "$(read_byte "$DEV" 123)" = "$B3" ]; then
                ui_print "Verification disabled, flags byte now $(flags_hex)"
                rm -f "$SECTOR" "$SECTOR.new"
                exit 0
            fi
            log "the whole disk write did not change the flags byte"
        else
            log "could not prepare the patched sector"
        fi
    else
        log "the data at sector $START of $DISK is not the vbmeta partition, not writing"
    fi
    rm -f "$SECTOR" "$SECTOR.new"
else
    log "partition offset or disk not found (part $PART, disk $DISK, start $START)"
fi

# 3. Odin package: the ROM zip ships vbmeta_disabled.tar (an unsigned vbmeta with the flags set, Odin
#    rejects a modified stock vbmeta), the installer extracts it to /tmp
ui_print "Cannot write vbmeta from the recovery"
if [ -s "$ODIN_TAR" ] && cp -f "$ODIN_TAR" "$ODIN_DIR/vbmeta_disabled.tar" >> "$LOGFILE" 2>&1; then
    ui_print "Before booting, flash $ODIN_DIR/vbmeta_disabled.tar with Odin (AP) in download mode"
else
    ui_print "Before booting, flash vbmeta_disabled.tar (in the ROM zip) with Odin (AP) in download mode"
fi
exit 1
