#!/bin/bash
#================================================================================================
#
# Flash FnNAS Hi3798MV100 image to USB/SD card
# Usage: sudo ./flash-image.sh <image.img.xz> <target-device>
#
#================================================================================================

set -e

IMAGE_FILE="${1}"
TARGET_DEVICE="${2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}INFO:${NC} $1"; }
warn() { echo -e "${YELLOW}WARN:${NC} $1"; }

# Check arguments
if [[ -z "$IMAGE_FILE" || -z "$TARGET_DEVICE" ]]; then
    echo "Usage: sudo $0 <image.img.xz> <target-device>"
    echo ""
    echo "Example:"
    echo "  sudo $0 fnnas_hisilicon_ec6100v9c_20240115.img.xz /dev/sdb"
    echo ""
    echo "Available images:"
    ls -la *.img.xz 2>/dev/null || echo "  (none in current directory)"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v loop
    exit 1
fi

# Check root
if [[ $EUID -ne 0 ]]; then
    error "Must run as root (use sudo)"
fi

# Check image exists
if [[ ! -f "$IMAGE_FILE" ]]; then
    error "Image file not found: $IMAGE_FILE"
fi

# Check target device exists
if [[ ! -b "$TARGET_DEVICE" ]]; then
    error "Target device not found: $TARGET_DEVICE"
fi

# Confirm target device
DEVICE_SIZE=$(lsblk -b -d -n -o SIZE "$TARGET_DEVICE" 2>/dev/null || echo 0)
DEVICE_MODEL=$(lsblk -d -n -o MODEL "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")
DEVICE_TRAN=$(lsblk -d -n -o TRAN "$TARGET_DEVICE" 2>/dev/null || echo "Unknown")

warn "Target device: $TARGET_DEVICE"
warn "  Model: $DEVICE_MODEL"
warn "  Transport: $DEVICE_TRAN"
warn "  Size: $((DEVICE_SIZE / 1024 / 1024)) MB"
echo ""

read -p "Are you sure you want to write to $TARGET_DEVICE? ALL DATA WILL BE LOST! (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    error "Aborted by user"
fi

# Decompress if needed
if [[ "$IMAGE_FILE" == *.xz ]]; then
    info "Decompressing image..."
    TEMP_IMG="${IMAGE_FILE%.xz}"
    if [[ ! -f "$TEMP_IMG" ]]; then
        xz -d -k -T0 "$IMAGE_FILE"
    fi
    IMAGE_FILE="$TEMP_IMG"
fi

# Verify image
info "Verifying image..."
if command -v sha256sum &>/dev/null && [[ -f "${IMAGE_FILE}.sha256" ]]; then
    sha256sum -c "${IMAGE_FILE}.sha256" || warn "Checksum verification failed!"
fi

# Unmount any mounted partitions
info "Unmounting any existing partitions on $TARGET_DEVICE..."
umount "${TARGET_DEVICE}"* 2>/dev/null || true

# Write image
info "Writing image to $TARGET_DEVICE..."
info "This may take several minutes..."
dd if="$IMAGE_FILE" of="$TARGET_DEVICE" bs=4M status=progress conv=fsync

# Sync
sync
info "Flashing complete!"

# Verify
info "Verifying write..."
PART_COUNT=$(lsblk -n -o NAME "$TARGET_DEVICE" | wc -l)
info "Partitions created: $((PART_COUNT - 1))"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DEVICE"

info "Done! You can now boot EC6100V9C from this device."
