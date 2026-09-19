# FnNAS Hisilicon Hi3798MV100 Port for EC6100V9C

> **既然ophub大佬不适配Hi3798MV100，那就自己适配**

本项目将飞牛 fnOS (FnNAS) ARM64 操作系统移植到基于海思 Hi3798MV100 芯片的 EC6100V9C 机顶盒。

## 🎯 核心原理

### 移植思路：基础镜像替换法

```
┌─────────────────────────────────────────────────────────────────┐
│                    移植核心流程                                    │
├─────────────────────────────────────────────────────────────────┤
│  1. 下载官方 fnOS ARM64 基础镜像 (Amlogic版本)                     │
│     └─ 包含完整的 Debian 根文件系统、fnOS 应用、启动脚本           │
│                                                                    │
│  2. 编译 Hi3798MV100 专用内核 + DTB                                │
│     ├─ 应用 David Yang v7 补丁 (CRG驱动、时钟绑定、MV100支持)     │
│     ├─ 启用 CONFIG_CLK_HI3798、CONFIG_MMC_DW_HI3798MV100 等       │
│     └─ 生成 Image.gz + hi3798mv100-ec6100v9c.dtb                  │
│                                                                    │
│  3. 解包基础镜像，替换内核/DTB/模块                                │
│     ├─ 替换 /boot/Image.gz                                        │
│     ├─ 替换 /boot/dtb/hisilicon/hi3798mv100-ec6100v9c.dtb        │
│     ├─ 替换 /lib/modules/ (Hi3798MV100 内核模块)                  │
│     └─ 重写 extlinux.conf / uEnv.txt (适配EC6100V9C启动参数)       │
│                                                                    │
│  4. 重新打包为标准 GPT 分区镜像                                    │
│     ├─ 分区1: FAT32 ESP (BOOT) - 512MB, 含内核、DTB、initramfs   │
│     └─ 分区2: BTRFS (ROOTFS) - 6GB+, 含完整根文件系统              │
│                                                                    │
│  5. 压缩输出 .img.xz，支持直接 dd 写入 U盘/SD卡/eMMC               │
└─────────────────────────────────────────────────────────────────┘
```

### 为什么选用 Amlogic 基础镜像？

- **ophub/fnnas 官方只发布 Amlogic/Rockchip/Allwinner 三个平台的基础镜像**
- **Hi3798MV100 (海思) 不在官方支持列表中**
- **核心用户空间 (systemd、Docker、fnOS Web UI) 是架构无关的 ARM64 二进制**
- **只需替换内核 + DTB + 模块，即可复用 99% 的用户空间**

### 关键技术难点与解决

| 难点 | 解决方案 |
|------|----------|
| **Hi3798MV100 CRG驱动未入主线** | 引入 David Yang v7 补丁系列 (2023年3月 LKML) |
| **时钟 ID 不同** | 补丁新增 HISTB_USB2_2_*、HISTB_FEPHY_CLK、HISTB_GPU_* 等 |
| **双 USB2 控制器** | DTS 同时配置 ohci/ehci @ 0x9880000 + ohci2/ehci2 @ 0x98a0000 |
| **eMMC 时钟分频** | 补丁定义 hi3798mv100_mmc_mux_p = {"75m","100m","50m","15m"} |
| **U-Boot 无 MV100 defconfig** | 以 hi3798cv200_defconfig 为基础，配合适配 DTB |
| **启动参数适配** | extlinux.conf + uEnv.txt 双配置，兼容 U-Boot 与 extlinux |

## 硬件规格

| 组件 | 规格 |
|------|------|
| **SoC** | HiSilicon Hi3798MV100 |
| **CPU** | 4× ARM Cortex-A7 @ 1.5 GHz |
| **RAM** | 1 GB DDR3 |
| **存储** | 8 GB eMMC |
| **以太网** | 1× 100 Mbps (内部 GMAC) |
| **USB** | 2× USB 2.0 (双控制器) |
| **视频解码** | 4K@30fps H.265/H.264 硬解 |
| **GPU** | Mali-450 (需厂商二进制固件) |
| **架构** | ARM64 (ARMv7-A with 64-bit extensions) |

## 项目结构

```
fnnas-hisilicon/
├── kernel/
│   ├── config-hi3798mv100          # 内核配置 (启用 CONFIG_CLK_HI3798)
│   └── patches/                    # Hi3798MV100 内核补丁 (David Yang v7)
│       ├── 0001-clk-hisilicon-Rename-Hi3798CV200-to-Hi3798.patch
│       ├── 0002-dt-bindings-clock-Add-Hi3798MV100-CRG.patch
│       └── 0003-clk-hisilicon-Add-CRG-driver-for-Hi3798MV100.patch
├── uboot/
│   └── hi3798mv100-ec6100v9c-u-boot.dtsi
├── dtb/
│   └── hi3798mv100-ec6100v9c.dts   # 使用补丁中的时钟 ID
├── scripts/
│   ├── build-fnnas-hisilicon.sh    # 一键构建 (自动应用补丁、生成U盘镜像)
│   ├── flash-image.sh              # 刷机工具 (交互式确认、校验)
│   └── first-boot-setup.sh         # 首启配置 (网络、SSH、Swap、CPU频率)
├── docs/
│   └── model_database.conf         # 设备数据库 (兼容 ophub 格式)
├── .github/workflows/
│   └── build-fnnas-hisilicon.yml   # GitHub Actions 自动化构建
└── README.md
```

## ⚡ 快速开始

### 方式一：本地编译 (推荐，完全可控)

```bash
# 1. 进入项目目录
cd /root/armfnos/fnnas-hisilicon

# 2. 一键编译 (需 root 权限，约 30-60 分钟)
sudo ./scripts/build-fnnas-hisilicon.sh -k 6.6.y -b ec6100v9c -s 6144 -n myname

# 3. 输出文件
# out/fnos_hisilicon_ec6100v9c_20241219_143022.img.xz
```

**编译产物说明：**
- ✅ 标准 GPT 分区表，兼容所有主流写盘工具
- ✅ 分区1 FAT32 ESP，UEFI/extlinux 双启动支持
- ✅ 分区2 BTRFS 根分区，支持压缩、快照、自动扩容
- ✅ 直接 `dd` 写入 U盘/SD卡 即可启动，**无需额外处理**

### 方式二：GitHub Actions 云编译 (零环境要求)

1. Fork 本仓库到你的 GitHub
2. 进入 **Actions** → **Build FnNAS Hi3798MV100 Image**
3. 点击 **Run workflow** → 选择 `6.6.y` → 运行
4. 构建完成后下载 Artifact (`.img.xz`)

## 💾 刷机指南

### U盘/SD卡启动 (推荐，无损原厂系统)

```bash
# 1. 解压镜像
xz -d fnnas_hisilicon_ec6100v9c_*.img.xz

# 2. 写入 U盘 (替换 /dev/sdX 为实际设备，如 /dev/sdb)
sudo ./scripts/flash-image.sh fnnas_hisilicon_ec6100v9c_*.img /dev/sdX

# 或手动 dd (加上 conv=fsync 确保数据落盘)
sudo dd if=fnnas_hisilicon_ec6100v9c_*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### 启动步骤

1. **插入 U盘** 到 EC6100V9C 背部 USB 接口
2. **接上 TTL** (115200 8N1，调试用)
3. **上电**，在 U-Boot 提示符下选择 USB 启动：
   ```
   => run bootcmd_usb
   # 或手动：
   => usb start
   => fatload usb 0:1 ${kernel_addr_r} Image.gz
   => fatload usb 0:1 ${fdt_addr_r} dtb/hisilicon/hi3798mv100-ec6100v9c.dtb
   => fatload usb 0:1 ${ramdisk_addr_r} initramfs.img
   => booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
   ```
4. 进入 fnOS 后，安装到 eMMC：
   ```bash
   sudo -i
   fnnas-install  # 按提示选择分区方案，完成后拔掉 U盘重启
   ```

### 直刷 eMMC (需 HiTool，Windows)

1. 盒子进入 **USB Burning Mode** (通常：按住 Reset 键上电)
2. 用 HiTool 打开 `.img` 文件 (解压后的)
3. 勾选 Hi3798MV100 对应的烧录配置
4. 点击开始烧录

## 🔧 首次启动自动配置

镜像内置 `first-boot-setup.sh`，首次启动自动执行：
- ✅ 网络配置 (eth0 DHCP)
- ✅ SSH 开启 (root 密码登录)
- ✅ 主机名设置 (fnnas-ec6100v9c)
- ✅ 根分区自动扩容到全盘
- ✅ 1GB Swap 文件创建 (1GB内存优化)
- ✅ CPU 频率调度 (ondemand, 600MHz-1.5GHz)
- ✅ 热力管理 (thermald, 70°C 被动降频)

## 🐛 故障排查

| 现象 | 原因 | 解决 |
|------|------|------|
| 卡在 BootROM | U-Boot 不匹配 | 确认用 hi3798cv200_defconfig + MV100 DTB |
| 无串口输出 | UART 地址错 | DTS 检查 `serial@8b00000` + `stdout-path` |
| Kernel panic: CRG | 补丁未应用 | 编译日志确认 `Applying 0003...` 成功 |
| eMMC 不识别 | DW MSHC 时钟 | DTS 验证 `HISTB_MMC_CIU_CLK` 等时钟引用 |
| 网卡不工作 | GMAC PHY | DTS 确认 `phy-mode = "rgmii"` + `phy-handle` |
| USB 不识别 | 缺少 USB2.2 时钟 | 补丁 0003 新增 `HISTB_USB2_2_*` 时钟 ID |

### 调试接口
```
TTL: 115200 8N1 (TX↔RX, GND↔GND)
U-Boot: =>
Linux: root@fnnas:~#
```

## 📚 技术参考

- **Hi3798MV100 CRG 补丁 (v7)**: https://lkml.org/lkml/2023/3/22/947
- **Linux 主线 Hi3798CV200 DT**: https://github.com/torvalds/linux/tree/master/arch/arm64/boot/dts/hisilicon
- **U-Boot Hi3798 支持**: https://github.com/u-boot/u-boot/tree/master/arch/arm/dts
- **ophub/fnnas 构建体系**: https://github.com/ophub/fnnas
- **EC6108V9 OpenWrt 参考**: https://gitee.com/chanjinn/hi3798mv100-openwrt
- **海思 STB 社区**: https://bbs.histb.com

## 许可证

- Linux kernel: GPL-2.0
- U-Boot: GPL-2.0+
- fnOS 基础镜像: 专有 (仅用于个人学习研究)
- 本项目脚本/补丁/文档: GPL-2.0
- Hi3798MV100 补丁: GPL-2.0 (David Yang 原作者)

## 致谢

- **David Yang** - Hi3798MV100 CRG 驱动补丁 (v7, 2023)
- **ophub/fnnas** - ARM64 构建框架、基础镜像
- **unifreq** - 电视盒子 Linux 内核维护
- **Jimmy (chanjinn)** - EC6108V9 OpenWrt 移植参考
- **海思 STB 社区** - 硬件资料、测试反馈

---

**免责声明**: 非官方移植，与飞牛官方、海思/华为无关。刷机有风险，**务必先备份原厂固件**。使用本项目产生的任何后果自负。

**最后更新**: 2024 | **目标 fnOS**: 1.2.x | **内核**: 6.6 LTS + Hi3798MV100 补丁
