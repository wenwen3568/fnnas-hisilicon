#!/bin/bash
#================================================================================================
#
# Build script for FnNAS on Hisilicon Hi3798MV100 (EC6100V9C)
# 生成可直接写入U盘启动的镜像
# 既然ophub大佬不适配Hi3798MV100，那就自己适配
#
#================================================================================================

set -e

# Colors
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
NOTE="[\033[93m NOTE \033[0m]"
WARNING="[\033[93m WARNING \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KERNEL_DIR="$PROJECT_ROOT/kernel"
UBOOT_DIR="$PROJECT_ROOT/uboot"
DTB_DIR="$PROJECT_ROOT/dtb"
BUILD_DIR="$PROJECT_ROOT/build"
OUTPUT_DIR="$PROJECT_ROOT/out"
PATCHES_DIR="$KERNEL_DIR/patches"

# Default configuration
BOARD="ec6100v9c"
KERNEL_VERSION="6.6.y"
KERNEL_REPO="https://github.com/torvalds/linux"
UBOOT_REPO="https://github.com/u-boot/u-boot"
ROOTFS_SIZE_MB=6144
BOOTFS_SIZE_MB=512
ROOTFS_EXPAND_GB=16
BUILDER_NAME="fnnas-hisilicon-$(whoami)"

# Base fnOS image (Amlogic版本作为基础，替换内核/DTB)
FNOS_BASE_IMAGE=""
FNOS_BASE_URL="https://github.com/ophub/fnnas/releases/download/fnnas_base_image/fnnas-official-arm64-image_amlogic_1252.img.xz"

error_msg() {
    echo -e " [💔] ${1}"
    exit 1
}

process_msg() {
    echo -e " [🌿] ${1}"
}

info_msg() {
    echo -e " [ℹ️] ${1}"
}

success_msg() {
    echo -e " [✅] ${1}"
}

warning_msg() {
    echo -e " [⚠️] ${1}"
}

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_msg "This script must be run as root (use sudo)"
    fi
}

# Install dependencies
install_dependencies() {
    process_msg "Installing build dependencies..."
    
    apt-get update -y
    apt-get install -y \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        make \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        device-tree-compiler \
        u-boot-tools \
        parted \
        dosfstools \
        e2fsprogs \
        btrfs-progs \
        xz-utils \
        curl \
        wget \
        git \
        python3 \
        python3-pip \
        qemu-user-static \
        binfmt-support \
        debootstrap \
        debian-archive-keyring \
        cpio \
        zstd \
        lz4 \
        pigz \
        rsync \
        patch
}

# Download base fnOS image
download_base_image() {
    process_msg "Downloading base fnOS ARM64 image (Amlogic版本作为基础)..."
    
    mkdir -p "$BUILD_DIR/base"
    cd "$BUILD_DIR/base"
    
    if [[ ! -f "fnnas-base.img.xz" ]]; then
        wget -c "$FNOS_BASE_URL" -O fnnas-base.img.xz
    fi
    
    if [[ ! -f "fnnas-base.img" ]]; then
        xz -d -k fnnas-base.img.xz
    fi
    
    FNOS_BASE_IMAGE="$BUILD_DIR/base/fnnas-base.img"
    success_msg "Base image ready: $FNOS_BASE_IMAGE"
}

# Build kernel with Hi3798MV100 patches
build_kernel() {
    process_msg "Building Linux kernel for Hi3798MV100 (应用David Yang v7补丁)..."
    
    mkdir -p "$BUILD_DIR/kernel"
    cd "$BUILD_DIR/kernel"
    
    if [[ ! -d "linux" ]]; then
        local kernel_branch="v${KERNEL_VERSION%.*}"
        git clone --depth=1 --branch "$kernel_branch" "$KERNEL_REPO" linux
    fi
    
    cd linux
    
    # Apply Hi3798MV100 patches
    process_msg "Applying Hi3798MV100 kernel patches (CRG驱动、DT bindings)..."
    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            if [[ -f "$patch" ]]; then
                info_msg "Applying $(basename "$patch")..."
                patch -p1 < "$patch" 2>/dev/null || warning_msg "Patch $(basename "$patch") may have already been applied"
            fi
        done
    fi
    
    # Copy config
    cp "$KERNEL_DIR/config-hi3798mv100" .config
    
    # Build
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image.gz
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) dtbs
    
    # Install modules
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$BUILD_DIR/kernel/rootfs" modules_install
    
    success_msg "Kernel build complete (含Hi3798MV100 CRG驱动)"
}

# Build U-Boot
build_uboot() {
    process_msg "Building U-Boot for Hi3798MV100..."
    
    mkdir -p "$BUILD_DIR/uboot"
    cd "$BUILD_DIR/uboot"
    
    if [[ ! -d "u-boot" ]]; then
        git clone --depth=1 "$UBOOT_REPO" u-boot
    fi
    
    cd u-boot
    
    # Copy device tree
    cp "$UBOOT_DIR/hi3798mv100-ec6100v9c-u-boot.dtsi" arch/arm/dts/
    
    # Configure for Hi3798CV200 (closest in mainline)
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- hi3798cv200_defconfig
    
    # Enable extlinux boot
    ./scripts/config --enable CMD_BOOTEFIMGR 2>/dev/null || true
    
    # Build
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc)
    
    success_msg "U-Boot build complete"
}

# Build device tree blobs
build_dtbs() {
    process_msg "Building device tree blobs..."
    
    mkdir -p "$BUILD_DIR/dtb"
    cd "$BUILD_DIR/kernel/linux"
    
    # Compile EC6100V9C DTB
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- hi3798mv100-ec6100v9c.dtb
    
    cp arch/arm64/boot/dts/hisilicon/hi3798mv100-ec6100v9c.dtb "$BUILD_DIR/dtb/"
    
    # Also compile U-Boot DTB
    cd "$BUILD_DIR/uboot/u-boot"
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- hi3798mv100-ec6100v9c.dtb
    cp hi3798mv100-ec6100v9c.dtb "$BUILD_DIR/dtb/u-boot-ec6100v9c.dtb"
    
    success_msg "DTB build complete"
}

# Extract base fnOS image
extract_base_image() {
    process_msg "Extracting base fnOS image..."
    
    mkdir -p "$BUILD_DIR/extract"
    cd "$BUILD_DIR/extract"
    
    local loop_dev=$(losetup -fP --show "$FNOS_BASE_IMAGE")
    
    mkdir -p boot
    mount "${loop_dev}p1" boot 2>/dev/null || mount "${loop_dev}p1" boot -t vfat
    
    mkdir -p root
    mount "${loop_dev}p2" root 2>/dev/null || mount "${loop_dev}p2" root -t btrfs -o compress=zstd:1
    
    mkdir -p "$BUILD_DIR/rootfs"
    rsync -a root/ "$BUILD_DIR/rootfs/"
    
    umount root boot
    losetup -d "$loop_dev"
    
    success_msg "Base image extracted"
}

# Replace kernel and DTB in rootfs
replace_kernel_dtb() {
    process_msg "Replacing kernel and DTB for Hi3798MV100..."
    
    local rootfs="$BUILD_DIR/rootfs"
    
    # Backup original kernel
    [[ -f "$rootfs/boot/Image.gz" ]] && mv "$rootfs/boot/Image.gz" "$rootfs/boot/Image.gz.bak"
    [[ -f "$rootfs/boot/Image" ]] && mv "$rootfs/boot/Image" "$rootfs/boot/Image.bak"
    
    # Copy new kernel
    cp "$BUILD_DIR/kernel/linux/arch/arm64/boot/Image.gz" "$rootfs/boot/Image.gz"
    
    # Copy DTBs
    mkdir -p "$rootfs/boot/dtb/hisilicon"
    cp "$BUILD_DIR/dtb/hi3798mv100-ec6100v9c.dtb" "$rootfs/boot/dtb/hisilicon/"
    
    # Update boot configuration for USB boot
    cat > "$rootfs/boot/extlinux.conf" << 'EXTLINUXEOF'
# FnNAS Hi3798MV100 EC6100V9C - extlinux.conf
# 既然ophub大佬不适配Hi3798MV100，那就自己适配
# 支持USB/SD/eMMC启动

UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT fnnas
MENU TITLE FnNAS Boot Menu (Hi3798MV100)

LABEL fnnas
    MENU LABEL FnNAS (Hi3798MV100 EC6100V9C)
    LINUX /Image.gz
    INITRD /initramfs.img
    FDT /dtb/hisilicon/hi3798mv100-ec6100v9c.dtb
    APPEND console=ttyAMA0,115200n8 earlycon=pl011,0xf8008b000000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw quiet

LABEL fnnas-recovery
    MENU LABEL FnNAS Recovery Mode
    LINUX /Image.gz
    INITRD /initramfs.img
    FDT /dtb/hisilicon/hi3798mv100-ec6100v9c.dtb
    APPEND console=ttyAMA0,115200n8 earlycon=pl011,0xf8008b000000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw single
EXTLINUXEOF

    # Also create uEnv.txt for U-Boot compatibility
    cat > "$rootfs/boot/uEnv.txt" << 'UENVEOF'
# FnNAS Hi3798MV100 EC6100V9C - uEnv.txt
# 既然ophub大佬不适配Hi3798MV100，那就自己适配

bootargs=console=ttyAMA0,115200n8 earlycon=pl011,0xf8008b000000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw quiet
fdtfile=hisilicon/hi3798mv100-ec6100v9c.dtb
kernel_file=Image.gz
initrd_file=initramfs.img
UENVEOF

    # Install kernel modules
    rsync -a "$BUILD_DIR/kernel/rootfs/lib/modules/" "$rootfs/lib/modules/"
    
    # Install firmware
    if [[ -d "$BUILD_DIR/kernel/linux/firmware" ]]; then
        rsync -a "$BUILD_DIR/kernel/linux/firmware/" "$rootfs/lib/firmware/"
    fi
    
    # Create initramfs if not exists
    if [[ ! -f "$rootfs/boot/initramfs.img" ]]; then
        process_msg "Creating initramfs..."
        chroot "$rootfs" /bin/bash -c "
            update-initramfs -c -k all 2>/dev/null || \
            mkinitramfs -o /boot/initramfs.img \$(ls /lib/modules | head -1) 2>/dev/null || \
            dracut --force /boot/initramfs.img \$(ls /lib/modules | head -1) 2>/dev/null || true
        " || warning_msg "initramfs creation failed, using base image's"
    fi
    
    success_msg "Kernel, DTB and boot config replaced"
}

# Create final USB-bootable image
create_image() {
    process_msg "Creating final USB-bootable fnOS image for EC6100V9C..."
    
    mkdir -p "$OUTPUT_DIR"
    
    local image_name="fnos_hisilicon_ec6100v9c_$(date +%Y%m%d_%H%M%S).img"
    local image_path="$OUTPUT_DIR/$image_name"
    
    # Calculate image size (额外空间给分区表和对齐)
    local total_size_mb=$((BOOTFS_SIZE_MB + ROOTFS_SIZE_MB + 200))
    
    # Create sparse image
    dd if=/dev/zero of="$image_path" bs=1M count=$total_size_mb status=progress
    
    # Partition: GPT + ESP + ROOTFS (适配U盘启动)
    parted -s "$image_path" mklabel gpt
    parted -s "$image_path" mkpart primary fat32 1MiB $((BOOTFS_SIZE_MB + 1))MiB
    parted -s "$image_path" set 1 boot on
    parted -s "$image_path" set 1 esp on
    parted -s "$image_path" name 1 "BOOT"
    parted -s "$image_path" mkpart primary btrfs $((BOOTFS_SIZE_MB + 1))MiB 100%
    parted -s "$image_path" name 2 "ROOTFS"
    
    # Setup loop device
    local loop_dev=$(losetup -fP --show "$image_path")
    
    # Format partitions
    mkfs.vfat -F 32 -n "BOOT" "${loop_dev}p1"
    mkfs.btrfs -L "ROOTFS" "${loop_dev}p2"
    
    # Mount and populate
    mkdir -p "$BUILD_DIR/image_mnt/boot"
    mkdir -p "$BUILD_DIR/image_mnt/root"
    
    mount "${loop_dev}p1" "$BUILD_DIR/image_mnt/boot"
    mount "${loop_dev}p2" "$BUILD_DIR/image_mnt/root" -o compress=zstd:1
    
    # Copy boot files (分区1: BOOT)
    rsync -a "$BUILD_DIR/rootfs/boot/" "$BUILD_DIR/image_mnt/boot/"
    
    # Copy rootfs (分区2: ROOTFS, 排除/boot)
    rsync -a --exclude=/boot "$BUILD_DIR/rootfs/" "$BUILD_DIR/image_mnt/root/"
    
    # Create boot directory in rootfs for bind mount
    mkdir -p "$BUILD_DIR/image_mnt/root/boot"
    
    # Unmount
    umount "$BUILD_DIR/image_mnt/boot"
    umount "$BUILD_DIR/image_mnt/root"
    losetup -d "$loop_dev"
    
    # Compress
    xz -T0 -9 "$image_path"
    
    success_msg "Final USB-bootable image created: ${image_path}.xz"
    
    # Generate checksum
    sha256sum "${image_path}.xz" > "${image_path}.xz.sha256"
    
    # 显示镜像信息
    echo ""
    echo "============================================"
    echo "  镜像信息"
    echo "============================================"
    echo "文件: ${image_path}.xz"
    echo "大小: $(du -h "${image_path}.xz" | cut -f1)"
    echo "SHA256: $(cat "${image_path}.xz.sha256" | cut -d' ' -f1)"
    echo ""
    echo "分区布局:"
    echo "  分区1 (BOOT): FAT32, ${BOOTFS_SIZE_MB}MB, ESP启动分区"
    echo "  分区2 (ROOTFS): BTRFS, ${ROOTFS_SIZE_MB}MB+, 根文件系统"
    echo ""
    echo "启动方式:"
    echo "  ✅ USB设备启动 (推荐)"
    echo "  ✅ SD卡启动"
    echo "  ✅ eMMC安装 (运行 fnnas-install)"
    echo "============================================"
}

# Main build function
main() {
    echo "============================================"
    echo "  FnNAS Hisilicon Hi3798MV100 Builder"
    echo "  Target: EC6100V9C STB"
    echo "  既然ophub大佬不适配Hi3798MV100，那就自己适配"
    echo "============================================"
    
    check_root
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--kernel)
                KERNEL_VERSION="$2"
                shift 2
                ;;
            -b|--board)
                BOARD="$2"
                shift 2
                ;;
            -s|--size)
                ROOTFS_SIZE_MB="$2"
                shift 2
                ;;
            -n|--name)
                BUILDER_NAME="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  -k, --kernel VERSION    Kernel version (default: 6.6.y)"
                echo "  -b, --board NAME        Board name (default: ec6100v9c)"
                echo "  -s, --size MB           Rootfs size in MB (default: 6144)"
                echo "  -n, --name NAME         Builder signature"
                echo "  -h, --help              Show this help"
                exit 0
                ;;
            *)
                error_msg "Unknown option: $1"
                ;;
        esac
    done
    
    # Create directories
    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
    
    # Build steps
    install_dependencies
    download_base_image
    build_kernel
    build_uboot
    build_dtbs
    extract_base_image
    replace_kernel_dtb
    create_image
    
    echo ""
    echo "============================================"
    success_msg "Build completed successfully! 🎉"
    echo "Output: $OUTPUT_DIR"
    ls -la "$OUTPUT_DIR"/*.img.xz 2>/dev/null || true
    echo ""
    echo "使用方法:"
    echo "  1. 解压: xz -d fnnas_hisilicon_ec6100v9c_*.img.xz"
    echo "  2. 写入U盘: sudo dd if=fnnas_hisilicon_ec6100v9c_*.img of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "  3. 插入EC6100V9C USB口，上电启动"
    echo "  4. 进入系统后: sudo fnnas-install  # 安装到eMMC"
    echo "============================================"
}

# Run main
main "$@"
