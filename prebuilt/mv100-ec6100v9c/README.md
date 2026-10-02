# Prebuilt Firmware for Hi3798MV100 EC6100V9C

This directory contains prebuilt firmware files extracted from the official mv100-mdmo1g-usb-flash.zip
for the EC6100V9C STB (Hi3798MV100 SoC).

## File Descriptions

| File | Description | Purpose |
|------|-------------|---------|
| `baseparam.img` | Base parameters | Hardware initialization parameters |
| `bootargs.bin` | Boot arguments (root) | Kernel boot arguments for rootfs |
| `fastboot.bin` | Fastboot binary (root) | Fastboot protocol implementation |
| `hi_kernel.bin` | **Kernel image with HDMI adaptation** | Main kernel binary (contains HDMI/DRM drivers for display) |
| `logo.img` | Boot logo | Startup splash screen |
| `pq_param.bin` | **Picture Quality parameters** | **HDMI display adaptation - color space, gamma, HDMI timing** |
| `recoverybox32.ext4` | Recovery partition (32-bit) | System recovery environment |
| `www_ecoo_top.ext4` | Root filesystem (ext4) | Main rootfs with applications |

## HDMI Display Adaptation Files

The following files are specifically for **HDMI display adaptation** on EC6100V9C:

1. **`hi_kernel.bin`** - Contains the kernel with DRM/KMS drivers for HiSilicon HDMI output
2. **`pq_param.bin`** - Picture Quality parameters for HDMI display calibration:
   - Color space conversion matrices
   - Gamma correction tables
   - HDMI timing parameters (pixel clock, sync polarities)
   - Video enhancement settings

## Usage

These prebuilt files can be used as a reference or fallback when building from source:
- Kernel: Use `hi_kernel.bin` instead of building from source (faster iteration)
- Display: `pq_param.bin` provides reference HDMI timing for EC6100V9C panel
- Rootfs: `www_ecoo_top.ext4` can be examined for vendor applications

## Source

Extracted from: `mv100-mdmo1g-usb-flash.zip`
Date: 2025-08-27 (recoverybox32.ext4), 2026-02-03 (www_ecoo_top.ext4, hi_kernel.bin)
Target: EC6100V9C (Hi3798MV100)

