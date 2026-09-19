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

# Base fnOS image
FNOS_BASE_IMAGE=""
FNOS_BASE_URL="https://github.com/ophub/fnnas/releases/download/fnnas_base_image/fnnas-official-arm64-image_amlogic_1252.img.xz"

error_msg() { echo -e " [💔] ${1}"; exit 1; }
process_msg() { echo -e " [🌿] ${1}"; }
info_msg() { echo -e " [ℹ️] ${1}"; }
success_msg() { echo -e " [✅] ${1}"; }
warning_msg() { echo -e " [⚠️] ${1}"; }

check_root() { [[ $EUID -ne 0 ]] && error_msg "Must run as root (use sudo)"; }

install_dependencies() {
    process_msg "Installing build dependencies..."
    apt-get update -y
    apt-get install -y \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu make bc bison flex \
        libssl-dev libelf-dev device-tree-compiler u-boot-tools \
        parted dosfstools e2fsprogs btrfs-progs xz-utils curl wget git \
        python3 python3-pip qemu-user-static binfmt-support \
        debootstrap debian-archive-keyring cpio zstd lz4 pigz rsync patch \
        initramfs-tools
}

download_base_image() {
    process_msg "Downloading base fnOS ARM64 image (Amlogic版本作为基础)..."
    mkdir -p "$BUILD_DIR/base"; cd "$BUILD_DIR/base"
    [[ ! -f "fnnas-base.img.xz" ]] && wget -c "$FNOS_BASE_URL" -O fnnas-base.img.xz
    [[ ! -f "fnnas-base.img" ]] && xz -d -k fnnas-base.img.xz
    FNOS_BASE_IMAGE="$BUILD_DIR/base/fnnas-base.img"
    success_msg "Base image ready: $FNOS_BASE_IMAGE"
}

build_kernel() {
    process_msg "Building Linux kernel for Hi3798MV100 (应用David Yang v7补丁)..."
    mkdir -p "$BUILD_DIR/kernel"; cd "$BUILD_DIR/kernel"
    [[ ! -d "linux" ]] && git clone --depth=1 --branch "v${KERNEL_VERSION%.*}" "$KERNEL_REPO" linux
    cd linux
    
    process_msg "Applying Hi3798MV100 kernel patches..."
    if [[ -d "$PATCHES_DIR" ]]; then
        for patch in "$PATCHES_DIR"/*.patch; do
            [[ -f "$patch" ]] && { info_msg "Applying $(basename "$patch")..."; patch -p1 < "$patch" 2>/dev/null || warning_msg "Patch $(basename "$patch") may have issues"; }
        done
    fi
    
    cp "$KERNEL_DIR/config-hi3798mv100" .config
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image.gz
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) dtbs
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$BUILD_DIR/kernel/rootfs" modules_install
    success_msg "Kernel build complete"
}

build_uboot() {
    process_msg "Building U-Boot for Hi3798MV100..."
    mkdir -p "$BUILD_DIR/uboot"; cd "$BUILD_DIR/uboot"
    [[ ! -d "u-boot" ]] && git clone --depth=1 "$UBOOT_REPO" u-boot
    cd u-boot
    cp "$UBOOT_DIR/hi3798mv100-ec6100v9c-u-boot.dtsi" arch/arm/dts/
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- hi3798cv200_defconfig
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc)
    success_msg "U-Boot build complete"
}

build_dtbs() {
    process_msg "Building device tree blobs..."
    mkdir -p "$BUILD_DIR/dtb"
    cd "$BUILD_DIR/kernel/linux"
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- hi3798mv100-ec6100v9c.dtb
    cp arch/arm64/boot/dts/hisilicon/hi3798mv100-ec6100v9c.dtb "$BUILD_DIR/dtb/"
    cd "$BUILD_DIR/uboot/u-boot"
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- hi3798mv100-ec6100v9c.dtb
    cp hi3798mv100-ec6100v9c.dtb "$BUILD_DIR/dtb/u-boot-ec6100v9c.dtb"
    success_msg "DTB build complete"
}

extract_base_image() {
    process_msg "Extracting base fnOS image..."
    mkdir -p "$BUILD_DIR/extract"; cd "$BUILD_DIR/extract"
    local loop_dev=$(losetup -fP --show "$FNOS_BASE_IMAGE")
    mkdir -p boot root
    mount "${loop_dev}p1" boot 2>/dev/null || mount "${loop_dev}p1" boot -t vfat
    mount "${loop_dev}p2" root 2>/dev/null || mount "${loop_dev}p2" root -t btrfs -o compress=zstd:1
    mkdir -p "$BUILD_DIR/rootfs"
    rsync -a root/ "$BUILD_DIR/rootfs/"
    umount root boot; losetup -d "$loop_dev"
    success_msg "Base image extracted"
}

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
    
    # ===== 关键：正确的启动参数 =====
    # UART0 物理地址: SOC基址 0xf0000000 + 偏移 0x8b00000 = 0xf8b00000
    # earlycon 格式: pl011,mmio32,0xf8b00000
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
    APPEND console=ttyAMA0,115200n8 earlycon=pl011,mmio32,0xf8b00000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw quiet

LABEL fnnas-recovery
    MENU LABEL FnNAS Recovery Mode
    LINUX /Image.gz
    INITRD /initramfs.img
    FDT /dtb/hisilicon/hi3798mv100-ec6100v9c.dtb
    APPEND console=ttyAMA0,115200n8 earlycon=pl011,mmio32,0xf8b00000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw single
EXTLINUXEOF

    # uEnv.txt for U-Boot
    cat > "$rootfs/boot/uEnv.txt" << 'UENVEOF'
# FnNAS Hi3798MV100 EC6100V9C - uEnv.txt
bootargs=console=ttyAMA0,115200n8 earlycon=pl011,mmio32,0xf8b00000 root=LABEL=ROOTFS rootfstype=btrfs rootflags=compress=zstd:1 rw quiet
fdtfile=hisilicon/hi3798mv100-ec6100v9c.dtb
kernel_file=Image.gz
initrd_file=initramfs.img
UENVEOF

    # Install kernel modules
    rsync -a "$BUILD_DIR/kernel/rootfs/lib/modules/" "$rootfs/lib/modules/"
    
    # Install firmware
    [[ -d "$BUILD_DIR/kernel/linux/firmware" ]] && rsync -a "$BUILD_DIR/kernel/linux/firmware/" "$rootfs/lib/firmware/"
    
    # ===== 强化 initramfs 生成 =====
    process_msg "Creating initramfs with Hi3798MV100 drivers..."
    local kver=$(ls "$rootfs/lib/modules/" | head -1)
    [[ -z "$kver" ]] && { warning_msg "No kernel modules found!"; return; }
    
    # Create initramfs hook for Hi3798 specific modules
    mkdir -p "$rootfs/etc/initramfs-tools/hooks"
    cat > "$rootfs/etc/initramfs-tools/hooks/hi3798mv100" << 'HOOKEOF'
#!/bin/sh
# Hi3798MV100 initramfs hook - ensure critical drivers are included
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions

# Force include Hi3798 MV100 drivers
manual_add_modules \
    dw_mmc_hisilicon \
    mmc_block \
    btrfs \
    crc32c_generic \
    libcrc32c \
    crc32c \
    xor \
    raid6_pq \
    btrfs \
    zstd_decompress \
    xxhash
HOOKEOF
    chmod +x "$rootfs/etc/initramfs-tools/hooks/hi3798mv100"
    
    # Ensure modules are in initramfs modules list
    mkdir -p "$rootfs/etc/initramfs-tools/modules.d"
    cat > "$rootfs/etc/initramfs-tools/modules.d/hi3798mv100" << 'MODULESEOF'
# Hi3798MV100 critical drivers for boot
dw_mmc_hisilicon
mmc_block
btrfs
crc32c_generic
libcrc32c
zstd_decompress
xxhash
MODULESEOF
    
    # Generate initramfs inside chroot
    chroot "$rootfs" /bin/bash -c "
        export KERNEL_VERSION=$kver
        update-initramfs -c -k $kver 2>/dev/null || \
        mkinitramfs -o /boot/initramfs.img $kver 2>/dev/null || \
        dracut --force /boot/initramfs.img $kver 2>/dev/null || true
    " || warning_msg "initramfs creation failed, will use base image's"
    
    # Verify initramfs exists
    [[ -f "$rootfs/boot/initramfs.img" ]] && success_msg "initramfs created: $(du -h $rootfs/boot/initramfs.img | cut -f1)"
    
    success_msg "Kernel, DTB, boot config, and initramfs ready"
}

create_image() {
    process_msg "Creating final USB-bootable fnOS image for EC6100V9C..."
    mkdir -p "$OUTPUT_DIR"
    local image_name="fnos_hisilicon_ec6100v9c_$(date +%Y%m%d_%H%M%S).img"
    local image_path="$OUTPUT_DIR/$image_name"
    local total_size_mb=$((BOOTFS_SIZE_MB + ROOTFS_SIZE_MB + 200))
    
    dd if=/dev/zero of="$image_path" bs=1M count=$total_size_mb status=progress
    parted -s "$image_path" mklabel gpt
    parted -s "$image_path" mkpart primary fat32 1MiB $((BOOTFS_SIZE_MB + 1))MiB
    parted -s "$image_path" set 1 boot on; parted -s "$image_path" set 1 esp on
    parted -s "$image_path" name 1 "BOOT"
    parted -s "$image_path" mkpart primary btrfs $((BOOTFS_SIZE_MB + 1))MiB 100%
    parted -s "$image_path" name 2 "ROOTFS"
    
    local loop_dev=$(losetup -fP --show "$image_path")
    mkfs.vfat -F 32 -n "BOOT" "${loop_dev}p1"
    mkfs.btrfs -L "ROOTFS" "${loop_dev}p2"
    
    mkdir -p "$BUILD_DIR/image_mnt/boot" "$BUILD_DIR/image_mnt/root"
    mount "${loop_dev}p1" "$BUILD_DIR/image_mnt/boot"
    mount "${loop_dev}p2" "$BUILD_DIR/image_mnt/root" -o compress=zstd:1
    
    rsync -a "$BUILD_DIR/rootfs/boot/" "$BUILD_DIR/image_mnt/boot/"
    rsync -a --exclude=/boot "$BUILD_DIR/rootfs/" "$BUILD_DIR/image_mnt/root/"
    mkdir -p "$BUILD_DIR/image_mnt/root/boot"
    
    umount "$BUILD_DIR/image_mnt/boot" "$BUILD_DIR/image_mnt/root"
    losetup -d "$loop_dev"
    
    xz -T0 -9 "$image_path"
    sha256sum "${image_path}.xz" > "${image_path}.xz.sha256"
    
    success_msg "Final USB-bootable image created: ${image_path}.xz"
    echo ""; echo "============================================"
    echo "  镜像信息: $(basename ${image_path}.xz)"; echo "  大小: $(du -h ${image_path}.xz | cut -f1)"
    echo "  SHA256: $(cat ${image_path}.xz.sha256 | cut -d' ' -f1)"
    echo ""; echo "分区布局:"
    echo "  分区1 (BOOT): FAT32, ${BOOTFS_SIZE_MB}MB, ESP启动分区"
    echo "  分区2 (ROOTFS): BTRFS, ${ROOTFS_SIZE_MB}MB+, 根文件系统"
    echo ""; echo "启动参数: console=ttyAMA0,115200n8 earlycon=pl011,mmio32,0xf8b00000"
    echo "  UART物理地址: 0xf8b00000 (SOC 0xf0000000 + 0x8b00000)"
    echo "============================================"
}

main() {
    echo "============================================"
    echo "  FnNAS Hisilicon Hi3798MV100 Builder"
    echo "  Target: EC6100V9C STB"
    echo "  既然ophub大佬不适配Hi3798MV100，那就自己适配"
    echo "============================================"
    check_root
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--kernel) KERNEL_VERSION="$2"; shift 2 ;;
            -b|--board) BOARD="$2"; shift 2 ;;
            -s|--size) ROOTFS_SIZE_MB="$2"; shift 2 ;;
            -n|--name) BUILDER_NAME="$2"; shift 2 ;;
            -h|--help) echo "Usage: $0 [-k kernel] [-b board] [-s size] [-n name]"; exit 0 ;;
            *) error_msg "Unknown option: $1" ;;
        esac
    done
    
    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
    install_dependencies
    download_base_image
    build_kernel
    build_uboot
    build_dtbs
    extract_base_image
    replace_kernel_dtb
    create_image
    
    echo ""; echo "============================================"
    success_msg "Build completed successfully! 🎉"
    echo "Output: $OUTPUT_DIR"
    ls -la "$OUTPUT_DIR"/*.img.xz 2>/dev/null || true
    echo ""; echo "使用方法:"
    echo "  1. 解压: xz -d fnnas_hisilicon_ec6100v9c_*.img.xz"
    echo "  2. 写入U盘: sudo dd if=fnnas_hisilicon_ec6100v9c_*.img of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "  3. 插入EC6100V9C USB口，上电启动 (TTL 115200 8N1)"
    echo "  4. 进入系统后: sudo fnnas-install  # 安装到eMMC"
    echo "============================================"
}

main "$@"
