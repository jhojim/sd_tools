#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

# Force English locale for all dialogs and tools
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# --- MASTER CONFIGURATION ---
export NEWT_COLORS='
  root=,blue
  window=,lightgray
  border=blue,lightgray
  title=blue,lightgray
  textbox=black,lightgray
  button=white,blue
  actbutton=white,cyan
  checkbox=blue,lightgray
  actcheckbox=white,blue
  entry=white,blue
  label=black,lightgray
  listbox=black,lightgray
  actlistbox=white,blue
'

# --- DIRECTORY RESOLUTION ---
# Get the absolute path of the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
BACKUP_DIR="$SCRIPT_DIR/images"
LOGFILE="$SCRIPT_DIR/sd_manager.log"

REAL_USER=${SUDO_USER:-$USER}

# Global variable to safely return values from UI functions
RET_VAL=""

# Create local image directory if it doesn't exist and fix permissions
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    chown "$REAL_USER:$REAL_USER" "$BACKUP_DIR"
fi

if [[ $EUID -ne 0 ]]; then
   whiptail --title "Error" --msgbox "This script must be run with sudo!\n\nTry: sudo $0" 10 50
   exit 1
fi

# Ensure logfile ownership is correct if created by root
touch "$LOGFILE"
chown "$REAL_USER:$REAL_USER" "$LOGFILE"

log_msg() {
    local level="$1"
    local msg="$2"
    echo -e "[$(date +'%H:%M:%S')] [${level}] ${msg}" | tee -a "$LOGFILE"
}

check_dependencies() {
    local REQUIRED_PACKAGES="coreutils parted e2fsprogs mount gzip whiptail dosfstools python3 tmux pv"
    local MISSING_PACKAGES=""
    for pkg in $REQUIRED_PACKAGES; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            MISSING_PACKAGES+="$pkg "
        fi
    done
    if [ -n "$MISSING_PACKAGES" ]; then
        echo "Installing missing dependencies: $MISSING_PACKAGES..."
        env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update -qq || true
        env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -yq $MISSING_PACKAGES
    fi
}

# --- UI FUNCTIONS (BULLETPROOF) ---
select_device() {
    local title="$1"
    local tempfile=$(mktemp)
    local DEVICES_LIST=$(lsblk -d -P -o NAME,SIZE,RM,MODEL -e 7)
    local ARGS=()
    local DEVICE_COUNT=0

    while read -r line; do
        eval "$line"
        if [ "$RM" == "1" ] && [ "$SIZE" != "0B" ] && [ -n "$SIZE" ]; then
            ARGS+=("$NAME" "$SIZE $MODEL")
            DEVICE_COUNT=$((DEVICE_COUNT+1))
        fi
    done <<< "$DEVICES_LIST"

    if [ $DEVICE_COUNT -eq 0 ]; then
        whiptail --title "Error" --msgbox "No removable devices found!" 8 45
        rm -f "$tempfile"
        return 1
    fi

    # Append separator and BACK option to the end
    ARGS+=("---" "---------------------------------------")
    ARGS+=("BACK" "<- Return to previous menu")

    local DEVICE=""
    while true; do
        local ret=0
        whiptail --title "$title" --cancel-button "Back" --menu "Select the SD card device:" 15 60 7 -- "${ARGS[@]}" 2> "$tempfile" || ret=$?
        DEVICE=$(cat "$tempfile")
        rm -f "$tempfile"

        if [ $ret -ne 0 ] || [ "$DEVICE" = "BACK" ]; then
            return 1
        elif [ "$DEVICE" = "---" ]; then
            continue
        else
            break
        fi
    done
    RET_VAL="/dev/$DEVICE"
    return 0
}

select_devices_multiple() {
    local title="$1"
    local tempfile=$(mktemp)
    local DEVICES_LIST=$(lsblk -d -P -o NAME,SIZE,RM,MODEL -e 7)
    local ARGS=()

    while read -r line; do
        eval "$line"
        if [ "$RM" == "1" ] && [ "$SIZE" != "0B" ] && [ -n "$SIZE" ]; then
            ARGS+=("$NAME" "$SIZE $MODEL" "OFF")
        fi
    done <<< "$DEVICES_LIST"

    if [ ${#ARGS[@]} -eq 0 ]; then
        whiptail --title "Error" --msgbox "No active USB/SD devices found!" 8 45
        rm -f "$tempfile"
        return 1
    fi

    local ret=0
    whiptail --title "$title" --cancel-button "Back" --checklist "Select SD cards to flash (SPACE to select):" 15 70 5 "${ARGS[@]}" 2> "$tempfile" || ret=$?
    local SELECTED=$(cat "$tempfile")
    rm -f "$tempfile"

    if [ $ret -ne 0 ] || [ -z "$SELECTED" ]; then return 1; fi

    local PARSED=""
    for dev in ${SELECTED//\"/}; do
        PARSED+="/dev/$dev "
    done
    RET_VAL="$PARSED"
    return 0
}

# --- 1. FORMAT FUNCTION ---
format_sd() {
    select_device "Format SD Card" || return 0
    local TARGET="$RET_VAL"

    if whiptail --title "WARNING" --yesno "ALL DATA ON $TARGET WILL BE ERASED!\nAre you absolutely sure?" 10 60; then
        clear
        log_msg "INFO" "Formatting $TARGET..."
        umount "${TARGET}"* 2>/dev/null || true
        wipefs -a "$TARGET"
        parted -s "$TARGET" mklabel msdos
        parted -s "$TARGET" mkpart primary fat32 1MiB 100%
        mkfs.vfat -F 32 "${TARGET}1"
        whiptail --title "Success" --msgbox "Device $TARGET formatted as FAT32." 8 45
    fi
}

# --- 2. SMART BACKUP & OPTIMIZE ---
create_backup() {
    select_device "Source for Backup" || return 0
    local TARGET="$RET_VAL"

    local tempfile=$(mktemp)
    local ret=0
    whiptail --title "Backup Name" --cancel-button "Back" --inputbox "Enter a name for your backup (leave empty for default):" 10 60 2> "$tempfile" || ret=$?
    local CUSTOM_NAME=$(cat "$tempfile")
    rm -f "$tempfile"

    if [ $ret -ne 0 ]; then return; fi

    local FINAL_NAME="sd_backup_$(date +%Y%m%d_%H%M)"
    if [ -n "$CUSTOM_NAME" ]; then
        FINAL_NAME=$(echo "$CUSTOM_NAME" | tr ' ' '_' | sed 's/[^a-zA-Z0-9._-]//g')
    fi

    local RAW_IMG="$BACKUP_DIR/${FINAL_NAME}.img"
    local LOOP=""
    local MOUNT_PT=""

    cleanup() {
        log_msg "INFO" "Cleaning up resources..."
        if [ -n "$MOUNT_PT" ] && mountpoint -q "$MOUNT_PT"; then
            umount -f "$MOUNT_PT" 2>/dev/null || true
        fi
        if [ -n "$MOUNT_PT" ] && [ -d "$MOUNT_PT" ]; then
            rmdir "$MOUNT_PT" 2>/dev/null || true
        fi
        if [ -n "$LOOP" ]; then
            losetup -d "$LOOP" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT INT TERM ERR

    clear
    log_msg "PROCESS" "Step 1: Copying full SD card $TARGET -> ${FINAL_NAME}.img..."
    local DEV_SIZE=$(blockdev --getsize64 "$TARGET")
    pv -tpreb -s "$DEV_SIZE" "$TARGET" > "$RAW_IMG"
    sync

    log_msg "PROCESS" "Step 2: Mounting image filesystem via loop device..."
    LOOP=$(losetup -fP --show "$RAW_IMG")

    local ROOT_DEV=$(lsblk -lno NAME -p "$LOOP" | grep -v "^$LOOP$" | tail -n 1)
    local ROOT_PART=$(basename "$ROOT_DEV")

    log_msg "INFO" "Checking root filesystem integrity on $ROOT_DEV..."
    e2fsck -fy "$ROOT_DEV" || [ $? -le 2 ]

    log_msg "INFO" "Zeroing free space for maximum GZIP compression layout..."
    MOUNT_PT=$(mktemp -d)
    mount "$ROOT_DEV" "$MOUNT_PT"
    local FREE_SPACE=$(df -B1 "$MOUNT_PT" | tail -n 1 | awk '{print $4}')
    pv -tpreb -s "$FREE_SPACE" /dev/zero > "$MOUNT_PT/zero.file" || true
    rm -f "$MOUNT_PT/zero.file"

    log_msg "INFO" "Injecting native filesystem auto-expand triggers..."
    if [ -f "$MOUNT_PT/usr/sbin/armbian-resize-firstboot" ] || [ -f "$MOUNT_PT/lib/armbian/armbian-resize-firstboot" ]; then
        log_msg "INFO" "Armbian detected. Activating native first-boot resizer daemon."
        rm -f "$MOUNT_PT/root/.no_automatic_fs_resize" 2>/dev/null || true
    fi

    if [ -f "$MOUNT_PT/usr/bin/raspi-config" ]; then
        log_msg "INFO" "Raspberry Pi OS detected. Injecting custom systemd resize service."
        cat <<'EOF' > "$MOUNT_PT/etc/systemd/system/rpi-expandfs.service"
[Unit]
Description=One-shot Root FS Expander
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/raspi-config nonint do_expand_rootfs
ExecStartPost=/bin/systemctl disable rpi-expandfs.service
ExecStartPost=/bin/rm -f /etc/systemd/system/rpi-expandfs.service

[Install]
WantedBy=multi-user.target
EOF
        mkdir -p "$MOUNT_PT/etc/systemd/system/multi-user.target.wants"
        ln -sf /etc/systemd/system/rpi-expandfs.service "$MOUNT_PT/etc/systemd/system/multi-user.target.wants/rpi-expandfs.service"
    fi

    umount "$MOUNT_PT"
    MOUNT_PT=""

    log_msg "INFO" "Final filesystem check before truncation..."
    e2fsck -fy "$ROOT_DEV" || [ $? -le 2 ]

    log_msg "PROCESS" "Optimizing ext4 partition filesystem to minimum boundary..."
    resize2fs -M "$ROOT_DEV"

    local PART_NUM=$(echo "$ROOT_PART" | grep -oE '[0-9]+$')
    local PART_START=$(parted -m "$RAW_IMG" unit B print | grep "^${PART_NUM}" | cut -d: -f 2 | tr -d B)
    local BLOCK_SIZE=$(tune2fs -l "$ROOT_DEV" | grep "Block size" | awk '{print $3}')
    local BLOCK_COUNT=$(tune2fs -l "$ROOT_DEV" | grep "Block count" | awk '{print $3}')
    local FS_SIZE=$((BLOCK_COUNT * BLOCK_SIZE))
    local NEW_END=$((PART_START + FS_SIZE + 52428800))

    log_msg "PROCESS" "Compacting image partition boundaries table..."
    losetup -d "$LOOP"
    LOOP=""

    parted -s "$RAW_IMG" rm "$PART_NUM"
    parted -s "$RAW_IMG" unit B mkpart primary "$PART_START" "$NEW_END"

    log_msg "PROCESS" "Cutting off trailing unallocated raw bytes and compressing..."
    truncate -s "$((NEW_END + 10485760))" "$RAW_IMG"
    pv "$RAW_IMG" | gzip > "${RAW_IMG}.gz"
    rm -f "$RAW_IMG"

    chown "$REAL_USER:$REAL_USER" "${RAW_IMG}.gz"
    trap - EXIT INT TERM ERR

    whiptail --title "Success" --msgbox "Smart Backup completed!\nSaved to: ${FINAL_NAME}.img.gz" 10 60
}

# --- 3. PARALLEL RESTORE & AUTO-EXPAND ---
flash_image() {
    local FILES=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.gz" \))
    if [ -z "$FILES" ]; then
        whiptail --msgbox "No images found in $BACKUP_DIR" 8 45; return 0
    fi
    local ARGS=()
    while read -r path; do
        if [ -n "$path" ]; then
            local filename=$(basename "$path")
            local desc="Raw Image"
            if [[ "$filename" =~ \.gz$ ]]; then
                desc="Compressed"
            fi
            ARGS+=("$filename" "$desc")
        fi
    done <<< "$FILES"
    ARGS+=("---" "---------------------------------------")
    ARGS+=("BACK" "<- Return to previous menu")

    local SELECTED_FILE=""
    while true; do
        local tempfile=$(mktemp)
        local ret=0
        whiptail --title "Select Image" --cancel-button "Back" --menu "Choose image to flash (from $BACKUP_DIR):" 15 80 7 -- "${ARGS[@]}" 2> "$tempfile" || ret=$?
        SELECTED_FILE=$(cat "$tempfile")
        rm -f "$tempfile"

        if [ $ret -ne 0 ] || [ "$SELECTED_FILE" = "BACK" ]; then
            return 0
        elif [ "$SELECTED_FILE" = "---" ]; then
            continue
        else
            break
        fi
    done
    local IMG_PATH="$BACKUP_DIR/$SELECTED_FILE"

    select_devices_multiple "Select Flash Destinations" || return 0
    local TARGETS="$RET_VAL"

    local TARGETS_PRETTY=$(echo "$TARGETS" | tr ' ' '\n')

    if whiptail --title "CRITICAL WARNING" --yesno "THIS WILL ERASE EVERYTHING ON:\n$TARGETS_PRETTY\nFlash $IMG_PATH to selected targets?" 15 70; then
        clear
        log_msg "PROCESS" "Starting parallel flashing of $IMG_PATH to multiple targets..."

        cat << 'EOF' > /tmp/sd_flash_worker.sh
#!/bin/bash
IMG_PATH="$1"
TARGET="$2"

echo "============================================"
echo "Preparing to flash $TARGET..."
umount "${TARGET}"* 2>/dev/null || true
umount -l "${TARGET}"* 2>/dev/null || true

python3 -c '
import sys
import os
import time
import gzip

try:
    img_path = sys.argv[1]
    target_dev = sys.argv[2]

    total_size = 0
    if img_path.endswith(".gz"):
        try:
            with gzip.open(img_path, "rb") as f:
                header = f.read(512)
            if len(header) >= 512 and header[510:512] == b"\x55\xaa":
                max_sector = 0
                for i in range(4):
                    offset = 446 + i * 16
                    part_type = header[offset + 4]
                    if part_type != 0:
                        start_sector = int.from_bytes(header[offset+8:offset+12], "little")
                        num_sectors = int.from_bytes(header[offset+12:offset+16], "little")
                        end_sector = start_sector + num_sectors
                        if end_sector > max_sector:
                            max_sector = end_sector
                if max_sector > 0:
                    total_size = max_sector * 512
        except Exception:
            pass

        if total_size <= 0:
            try:
                with open(img_path, "rb") as f:
                    f.seek(-4, 2)
                    total_size = int.from_bytes(f.read(), "little")
            except Exception:
                pass
            compressed_size = os.path.getsize(img_path)
            if total_size < compressed_size:
                while total_size < compressed_size:
                    total_size += 4294967296
            if total_size < 1000000:
                total_size = compressed_size * 3
    else:
        total_size = os.path.getsize(img_path)

    if img_path.endswith(".gz"):
        src = gzip.open(img_path, "rb")
    else:
        src = open(img_path, "rb")

    dst_fd = os.open(target_dev, os.O_WRONLY | os.O_SYNC)

    chunk_size = 4 * 1024 * 1024
    written = 0
    start_time = time.time()

    print(f"Flashing: {os.path.basename(img_path)} -> {target_dev}")
    print(f"Total size: {total_size / 1024 / 1024 / 1024:.2f} GB")

    while True:
        chunk = src.read(chunk_size)
        if not chunk:
            break
        os.write(dst_fd, chunk)
        written += len(chunk)

        elapsed = time.time() - start_time
        speed = written / elapsed if elapsed > 0 else 0
        percent = min(100.0, (written / total_size) * 100) if total_size > 0 else 0
        eta = (total_size - written) / speed if speed > 0 else 0

        bar_width = 30
        filled = int(percent / 100 * bar_width)
        bar = "#" * filled + "-" * (bar_width - filled)

        speed_mb = speed / 1024 / 1024
        written_gb = written / 1024 / 1024 / 1024
        total_gb = total_size / 1024 / 1024 / 1024

        eta_str = time.strftime("%M:%S", time.gmtime(eta)) if eta < 3600 else ">1hr"

        sys.stdout.write(
            f"\r[{bar}] {percent:.1f}% | {written_gb:.2f}/{total_gb:.2f} GB | {speed_mb:.1f} MB/s | ETA: {eta_str}  "
        )
        sys.stdout.flush()

    os.fdatasync(dst_fd)
    src.close()
    os.close(dst_fd)
    print("\nFlash finished successfully.")
    sys.exit(0)
except Exception as e:
    print(f"\nERROR during flash: {e}", file=sys.stderr)
    sys.exit(1)
' "$IMG_PATH" "$TARGET"

if [ $? -ne 0 ]; then
    echo "Python flash failed. Aborting expansion."
    exit 1
fi

echo "--------------------------------------------"
echo "Expanding partition and filesystem to 100% on host..."

partprobe "$TARGET" || true
sleep 1

HOST_PART_NUM=$(lsblk -lno NAME "$TARGET" | grep -v "^$(basename "$TARGET")$" | tail -n 1 | grep -oE '[0-9]+$')

HOST_PART_DEV=""
if [[ "$TARGET" =~ [0-9]$ ]]; then
    HOST_PART_DEV="${TARGET}p${HOST_PART_NUM}"
else
    HOST_PART_DEV="${TARGET}${HOST_PART_NUM}"
fi

echo "Expanding partition table slot $HOST_PART_NUM on $TARGET to 100% boundary..."
parted -s "$TARGET" resizepart "$HOST_PART_NUM" 100%

partprobe "$TARGET" || true
sleep 1

echo "Growing target ext4 filesystem maps live on $HOST_PART_DEV..."
e2fsck -fy "$HOST_PART_DEV" || true
resize2fs "$HOST_PART_DEV"

echo "============================================"
echo "SUCCESS! $TARGET is fully flashed and expanded."
echo "============================================"
EOF

        chmod +x /tmp/sd_flash_worker.sh

        local SESSION="sd_flash_$(date +%s)"
        tmux new-session -d -s "$SESSION"

        local i=0
        for dev in $TARGETS; do
            if [ $i -gt 0 ]; then
                tmux split-window -h
                tmux select-layout tiled
            fi
            tmux send-keys "sudo /tmp/sd_flash_worker.sh '$IMG_PATH' '$dev'; echo 'Press Enter to close this window...'; read; exit" C-m
            i=$((i+1))
        done

        tmux select-layout tiled
        tmux attach-session -t "$SESSION"
        rm -f /tmp/sd_flash_worker.sh
    fi
}

# --- 4. OPTIMIZE & COMPRESS EXISTING IMAGE ---
optimize_existing_image() {
    local FILES=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.img")
    if [ -z "$FILES" ]; then
        whiptail --msgbox "No raw .img files found in $BACKUP_DIR" 8 45; return 0
    fi
    local ARGS=()
    while read -r path; do
        [ -n "$path" ] && ARGS+=("$(basename "$path")" "Raw Image")
    done <<< "$FILES"
    ARGS+=("---" "---------------------------------------")
    ARGS+=("BACK" "<- Return to previous menu")

    local SELECTED_FILE=""
    while true; do
        local tempfile=$(mktemp)
        local ret=0
        whiptail --title "Select Image" --cancel-button "Back" --menu "Choose image to optimize/compress (from $BACKUP_DIR):" 15 80 7 -- "${ARGS[@]}" 2> "$tempfile" || ret=$?
        SELECTED_FILE=$(cat "$tempfile")
        rm -f "$tempfile"

        if [ $ret -ne 0 ] || [ "$SELECTED_FILE" = "BACK" ]; then
            return 0
        elif [ "$SELECTED_FILE" = "---" ]; then
            continue
        else
            break
        fi
    done
    local IMG_PATH="$BACKUP_DIR/$SELECTED_FILE"

    local tempfile_part=$(mktemp)
    local CHOICE_PART=""
    while true; do
        local ret_part=0
        whiptail --title "Select Platform" --cancel-button "Back" --menu "Choose your platform (determines the root partition):" 15 65 5 -- \
        "1" "Armbian / Orange Pi (Partition 1)" \
        "2" "Raspberry Pi OS (Partition 2)" \
        "custom" "Custom Partition Number" \
        "---" "---------------------------------------" \
        "BACK" "<- Return to previous menu" 2> "$tempfile_part" || ret_part=$?
        CHOICE_PART=$(cat "$tempfile_part")
        rm -f "$tempfile_part"

        if [ $ret_part -ne 0 ] || [ "$CHOICE_PART" = "BACK" ]; then
            return 0
        elif [ "$CHOICE_PART" = "---" ]; then
            continue
        else
            break
        fi
    done

    local PART_NUM=""
    if [ "$CHOICE_PART" = "custom" ]; then
        local tempfile_custom=$(mktemp)
        local ret_custom=0
        whiptail --title "Custom Partition" --cancel-button "Back" --inputbox "Enter the root partition number manually:" 10 60 "1" 2> "$tempfile_custom" || ret_custom=$?
        PART_NUM=$(cat "$tempfile_custom")
        rm -f "$tempfile_custom"
        if [ $ret_custom -ne 0 ]; then return; fi
    else
        PART_NUM="$CHOICE_PART"
    fi
    if [ -z "$PART_NUM" ]; then PART_NUM=1; fi

    local LOOP=""
    local MOUNT_PT=""

    cleanup() {
        log_msg "INFO" "Cleaning up resources..."
        if [ -n "$MOUNT_PT" ] && mountpoint -q "$MOUNT_PT"; then
            umount -f "$MOUNT_PT" 2>/dev/null || true
        fi
        if [ -n "$MOUNT_PT" ] && [ -d "$MOUNT_PT" ]; then
            rmdir "$MOUNT_PT" 2>/dev/null || true
        fi
        if [ -n "$LOOP" ]; then
            losetup -d "$LOOP" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT INT TERM ERR

    clear
    log_msg "PROCESS" "Step 1: Mounting target raw image file via loop device node..."
    LOOP=$(losetup -fP --show "$IMG_PATH")

    local ROOT_DEV="${LOOP}p${PART_NUM}"
    local ROOT_PART=$(basename "$ROOT_DEV")

    log_msg "INFO" "Checking root filesystem integrity on $ROOT_DEV..."
    e2fsck -fy "$ROOT_DEV" || [ $? -le 2 ]

    log_msg "INFO" "Zeroing free space blocks allocation layout..."
    MOUNT_PT=$(mktemp -d)
    mount "$ROOT_DEV" "$MOUNT_PT"
    local FREE_SPACE=$(df -B1 "$MOUNT_PT" | tail -n 1 | awk '{print $4}')
    pv -tpreb -s "$FREE_SPACE" /dev/zero > "$MOUNT_PT/zero.file" || true
    rm -f "$MOUNT_PT/zero.file"

    log_msg "INFO" "Injecting native filesystem auto-expand triggers..."
    if [ -f "$MOUNT_PT/usr/sbin/armbian-resize-firstboot" ] || [ -f "$MOUNT_PT/lib/armbian/armbian-resize-firstboot" ]; then
        log_msg "INFO" "Armbian detected. Activating native first-boot resizer daemon."
        rm -f "$MOUNT_PT/root/.no_automatic_fs_resize" 2>/dev/null || true
    fi

    if [ -f "$MOUNT_PT/usr/bin/raspi-config" ]; then
        log_msg "INFO" "Raspberry Pi OS detected. Injecting custom one-shot systemd resize service."
        cat <<'EOF' > "$MOUNT_PT/etc/systemd/system/rpi-expandfs.service"
[Unit]
Description=One-shot Root FS Expander
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/raspi-config nonint do_expand_rootfs
ExecStartPost=/bin/systemctl disable rpi-expandfs.service
ExecStartPost=/bin/rm -f /etc/systemd/system/rpi-expandfs.service

[Install]
WantedBy=multi-user.target
EOF
        mkdir -p "$MOUNT_PT/etc/systemd/system/multi-user.target.wants"
        ln -sf /etc/systemd/system/rpi-expandfs.service "$MOUNT_PT/etc/systemd/system/multi-user.target.wants/rpi-expandfs.service"
    fi

    umount "$MOUNT_PT"
    MOUNT_PT=""

    log_msg "INFO" "Ensuring clean system table structure before optimization process execution..."
    e2fsck -fy "$ROOT_DEV" || [ $? -le 2 ]

    log_msg "PROCESS" "Compacting file system volume parameters..."
    resize2fs -M "$ROOT_DEV"

    local PART_START=$(parted -m "$IMG_PATH" unit B print | grep "^${PART_NUM}" | cut -d: -f 2 | tr -d B)
    local BLOCK_SIZE=$(tune2fs -l "$ROOT_DEV" | grep "Block size" | awk '{print $3}')
    local BLOCK_COUNT=$(tune2fs -l "$ROOT_DEV" | grep "Block count" | awk '{print $3}')
    local FS_SIZE=$((BLOCK_COUNT * BLOCK_SIZE))
    local NEW_END=$((PART_START + FS_SIZE + 52428800))

    log_msg "PROCESS" "Truncating raw file structural limits boundaries table..."
    losetup -d "$LOOP"
    LOOP=""

    parted -s "$IMG_PATH" rm "$PART_NUM"
    parted -s "$IMG_PATH" unit B mkpart primary "$PART_START" "$NEW_END"

    log_msg "PROCESS" "Truncating dead zero bytes structure blocks and compressing..."
    truncate -s "$((NEW_END + 10485760))" "$IMG_PATH"
    pv "$IMG_PATH" | gzip > "${IMG_PATH}.gz"

    chown "$REAL_USER:$REAL_USER" "${IMG_PATH}.gz"
    trap - EXIT INT TERM ERR

    whiptail --title "Success" --msgbox "Optimization & Compression completed!\nSaved to: ${IMG_PATH}.gz" 10 60
}

# --- MAIN EXECUTION LOOP ---
check_dependencies

while true; do
    tempfile=$(mktemp)
    ret=0
    whiptail --title "Image Provisioning Tool" --menu "Main Menu" 15 60 5 \
    "1" "Create Optimized Backup (Auto-size)" \
    "2" "Parallel Restore Image to SDs" \
    "3" "Format Target (FAT32)" \
    "4" "Optimize & Compress Existing Image" \
    "5" "Exit" 2> "$tempfile" || ret=$?
    CHOICE=$(cat "$tempfile")
    rm -f "$tempfile"

    if [ $ret -ne 0 ]; then exit 0; fi

    case "$CHOICE" in
        "1") create_backup ;;
        "2") flash_image ;;
        "3") format_sd ;;
        "4") optimize_existing_image ;;
        "5"|*) exit 0 ;;
    esac
done