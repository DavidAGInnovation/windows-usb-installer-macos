#!/usr/bin/env bash
set -euo pipefail

err() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Prompt for ISO path if not provided via env
ISO_PATH="${ISO_PATH:-}"
if [[ -z "$ISO_PATH" ]]; then
  echo "Enter the path to your Windows ISO (drag-and-drop is fine):"
  read -r -p "ISO path: " ISO_PATH
fi
# Tilde and quote cleanup for user input
ISO_PATH="${ISO_PATH/#\~/$HOME}"
ISO_PATH="${ISO_PATH%\"}"
ISO_PATH="${ISO_PATH#\"}"
ISO_PATH="${ISO_PATH%\'}"
ISO_PATH="${ISO_PATH#\'}"
[[ -f "$ISO_PATH" ]] || err "ISO not found at: $ISO_PATH"

# Basic extension warning (non-fatal) for non-.iso (case-insensitive, portable on macOS Bash)
case "$ISO_PATH" in
  *.iso|*.ISO) : ;;
  *)
    echo "Warning: The selected file does not have a .iso extension." >&2
    echo "Attempting to validate it as a disk image..." >&2
    ;;
esac

# Validate ISO by attempting to attach read-only and parse plist output (locale-agnostic)
info "Validating ISO..."
ISO_PLIST="$(mktemp -t iso_attach_XXXX.plist)"
if ! hdiutil attach -nobrowse -readonly -plist "$ISO_PATH" > "$ISO_PLIST" 2>/dev/null; then
  rm -f "$ISO_PLIST"
  err "Failed to recognize or mount the image as an ISO/disk image. Please select a valid Windows .iso."
fi
ISO_MOUNT="$(awk -F'[<>]' '/<key>mount-point<\/key>/{getline; if ($3!="") {print $3; exit}}' "$ISO_PLIST")"
rm -f "$ISO_PLIST"
[[ -n "$ISO_MOUNT" && -d "$ISO_MOUNT" ]] || err "Failed to determine ISO mount point. Please ensure the ISO is valid."
info "ISO mounted at: $ISO_MOUNT"

# Prepare cleanup early so ISO gets detached even if we abort later
cleanup() {
  info "Cleaning up..."
  if [[ -n "${ISO_MOUNT:-}" ]]; then
    hdiutil detach "$ISO_MOUNT" >/dev/null 2>&1 || true
  fi
  if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Prompt for target disk if not provided via env
DISK="${DISK:-}"
if [[ -z "$DISK" ]]; then
  echo "Available disks:"
  diskutil list
  echo
  echo "Enter the target USB disk (e.g., /dev/disk3 or disk3). THIS WILL BE ERASED."
  read -r -p "Disk: " DISK
fi
DISK="$(printf %s "$DISK" | awk '{gsub(/^\s+|\s+$/,"",$0); print}')"
DISK="${DISK%\"}"
DISK="${DISK#\"}"
DISK="${DISK%\'}"
DISK="${DISK#\'}"
[[ -n "$DISK" ]] || err "No disk specified."
[[ "$DISK" == /dev/* ]] || DISK="/dev/$DISK"

# Sanity checks
diskutil info "$DISK" >/dev/null 2>&1 || err "Disk $DISK not found. Use 'diskutil list' to locate your USB."
ROOT_WHOLE_DISK="$(diskutil info / | awk -F': *' '/Part of Whole/ {print $2}')"
if [[ "$DISK" == "/dev/${ROOT_WHOLE_DISK}" ]]; then
  err "Refusing to operate on the system disk: $DISK"
fi

DEVICE_LOCATION="$(diskutil info "$DISK" | awk -F': *' '/Device Location/ {print $2}' || true)"
if [[ "$DEVICE_LOCATION" != "External" && "$DEVICE_LOCATION" != "Removable" ]]; then
  echo "Warning: $DISK does not appear to be External/Removable. Proceed with extreme caution." >&2
fi

## Ask for volume label (default WINUSB). You can pre-set USB_LABEL env.
USB_LABEL="${USB_LABEL:-}"
if [[ -z "$USB_LABEL" ]]; then
  read -r -p "Enter a volume label for the USB [default: WINUSB]: " USB_LABEL || true
fi
USB_LABEL="$(printf %s "${USB_LABEL:-}" | awk '{gsub(/^\s+|\s+$/,"",$0); print}')"
USB_LABEL="${USB_LABEL%\"}"; USB_LABEL="${USB_LABEL#\"}"; USB_LABEL="${USB_LABEL%\'}"; USB_LABEL="${USB_LABEL#\'}"
if [[ -z "$USB_LABEL" ]]; then USB_LABEL="WINUSB"; fi

echo "About to ERASE $DISK and create a Windows USB installer from:"
echo "  ISO:  $ISO_PATH"
echo "  Disk: $DISK"
echo "  Label: $USB_LABEL"
read -r -p "Continue? [y/N] " RESP
[[ "${RESP:-}" =~ ^[Yy]$ ]] || err "Aborted."

# Unmount and erase the USB as GPT + FAT32
info "Erasing $DISK as GPT + MS-DOS (FAT32) named $USB_LABEL..."
diskutil unmountDisk force "$DISK" >/dev/null 2>&1 || true
diskutil eraseDisk MS-DOS "$USB_LABEL" GPT "$DISK"

# Ensure the FAT32 partition is mounted and capture its mount point
USB_VOL_NAME="$USB_LABEL"
USB_VOL="/Volumes/$USB_VOL_NAME"

# Find the FAT32 partition we just created
PARTITION_ID="$(diskutil list "$DISK" | awk -v N="$USB_VOL_NAME" '($0 ~ N) && ($0 ~ /Microsoft Basic Data|Windows_FAT_32|DOS_FAT_32|MS-DOS/) {print $NF; exit}')"
if [[ -z "$PARTITION_ID" ]]; then
  PARTITION_ID="$(diskutil list "$DISK" | awk '/Windows_FAT_32|DOS_FAT_32|Microsoft Basic Data/ {id=$NF} END {print id}')"
fi

if [[ -n "$PARTITION_ID" ]]; then
  diskutil mount "/dev/$PARTITION_ID" >/dev/null 2>&1 || true
  MP="$(diskutil info "/dev/$PARTITION_ID" | awk -F': *' '/Mount Point/ {print $2; exit}')"
  if [[ -n "$MP" && "$MP" != "Not Mounted" ]]; then
    USB_VOL="$MP"
  fi
fi

# Wait briefly for the volume to appear
for i in {1..15}; do
  if [[ -d "$USB_VOL" ]]; then
    break
  fi
  sleep 1
done
[[ -d "$USB_VOL" ]] || err "USB volume not mounted at $USB_VOL after erase. Try unplug/replug, then rerun."

# Ensure the filesystem label matches USB_LABEL for consistent appearance in macOS/Windows
CURRENT_LABEL="$(basename "$USB_VOL")"
if [[ "$CURRENT_LABEL" != "$USB_LABEL" ]]; then
  info "Setting volume label to $USB_LABEL..."
  if diskutil renameVolume "$USB_VOL" "$USB_LABEL" >/dev/null 2>&1; then
    USB_VOL="/Volumes/$USB_LABEL"
    for i in {1..10}; do
      [[ -d "$USB_VOL" ]] && break
      sleep 1
    done
  else
    echo "Warning: Unable to rename volume label; continuing with '$CURRENT_LABEL'." >&2
  fi
fi

# Show partition layout and explain boot options
info "Partition layout for $DISK:"
diskutil list "$DISK"
echo "Note: This USB has two partitions — s1: EFI System Partition, s2: $USB_LABEL (FAT32)."
echo "      In the boot menu, choose the UEFI entry for Partition 2 ($USB_LABEL)."

# ISO already mounted during validation; ensure it looks good
[[ -n "$ISO_MOUNT" && -d "$ISO_MOUNT" ]] || err "ISO not mounted after validation."

# cleanup/trap moved earlier (right after validation attach)

info "Copying files (excluding sources/install.wim)..."
rsync -avh --progress --exclude='sources/install.wim' "$ISO_MOUNT/" "$USB_VOL/"

# ESP population skipped by design; modern UEFI boots from \EFI\BOOT\BOOTX64.EFI on s2 ($USB_LABEL).

WIM_SRC="$ISO_MOUNT/sources/install.wim"
WIM_DST_DIR="$USB_VOL/sources"
mkdir -p "$WIM_DST_DIR"

if [[ -f "$WIM_SRC" ]]; then
  WIM_SIZE="$(stat -f%z "$WIM_SRC")"
  # 4 GiB limit for FAT32
  if (( WIM_SIZE > 4294967295 )); then
    info "install.wim is >4GiB ($((WIM_SIZE/1024/1024)) MiB). Splitting with wimlib..."
    if ! command -v wimlib-imagex >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then
        info "Installing wimlib via Homebrew..."
        brew install wimlib
      else
        err "wimlib-imagex not found and Homebrew is missing. Install Homebrew (+ wimlib) and rerun."
      fi
    fi
    # Default: stage split parts on SSD for speed; fallback to USB if space is insufficient
    STAGING_DIR="$(mktemp -d -t wim_split_XXXX)"
    # Check available space on staging filesystem
    AVAIL_KB="$(df -k "$STAGING_DIR" | awk 'NR==2{print $4}')"
    AVAIL_BYTES=$(( AVAIL_KB * 1024 ))
    if (( AVAIL_BYTES < WIM_SIZE )); then
      echo "Warning: Not enough free space on SSD staging (${AVAIL_BYTES} bytes) for WIM (${WIM_SIZE} bytes)." >&2
      echo "Falling back to splitting directly on the USB (slower)." >&2
      rm -rf "$STAGING_DIR"; unset STAGING_DIR
      wimlib-imagex split "$WIM_SRC" "$WIM_DST_DIR/install.swm" 3800
    else
      info "Staging split files on SSD: $STAGING_DIR"
      wimlib-imagex split "$WIM_SRC" "$STAGING_DIR/install.swm" 3800
      info "Copying split SWM files to USB..."
      rsync -avh --progress "$STAGING_DIR/"install*.swm "$WIM_DST_DIR/"
    fi
  else
    info "install.wim <=4GiB; copying directly..."
    cp -v "$WIM_SRC" "$WIM_DST_DIR/"
  fi
else
  echo "Warning: $WIM_SRC not found. The ISO may be unexpected." >&2
fi

sync

# Detach the ISO mount; leave USB mounted by default
hdiutil detach "$ISO_MOUNT" || true
info "Done. USB installer created. Left mounted at $USB_VOL"
