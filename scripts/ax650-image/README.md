# AX650 固件 → Docker 离线调试环境

把上科大 Magician 板的 `.axp` 固件包转成能在 **macOS 或 Ubuntu** 上直接跑的 `linux/arm64`
Docker 镜像，不用连板子。

这个 `.axp` 是 **上海科技大学自研 AX650 开发板「Magician」的发版固件**
（网盘分享目录名 `Magician_AX650X载板方案_EMMC_发版固件_1.0`，u-boot 标识串
`Magician Axera AX650 OVAI System`），也就是 EnvCfg 文档里说的"上科大定制 AX650 镜像"。
详见 [ENVCFG-REVIEW.md](ENVCFG-REVIEW.md)。

## 文件说明

```
scripts/ax650-image/
├── build.sh          .axp → Docker 镜像（跨平台，macOS + Ubuntu）
├── run.sh            进容器编译/调试（跨平台）
├── export.sh         把镜像打成一个文件，搬去别的机器
├── import.sh         在目标机器还原
├── sparse2raw.py     Android sparse 镜像 → raw（纯 Python，无依赖）
├── env/Dockerfile    ax650-env 的定义（可复现，可自己加包）
├── README.md         本文
├── TUTORIAL.md       从启动 Docker 开始的完整教程
├── ENVCFG-REVIEW.md  上科大 EnvCfg 的实测审计报告
├── ax650-images-V3.6.2.tar.zst      ← 已打好的镜像包（2.5 GB）+ .sha256，
│                                      直接 scp 到 Ubuntu 用 import.sh 还原
└── work/             中间产物（已 gitignore，约 13 GB，可随时删）
```

## 快速开始

### 在已经有镜像的机器上（比如你这台 Mac）

```bash
bash scripts/ax650-image/run.sh
# 容器里：
cmake -S . -B build -DINFERENCE_BACKEND=AXCL && cmake --build build -j"$(nproc)"
```

### 从固件重新构建

```bash
bash scripts/ax650-image/build.sh --axp /path/to/AX650_emmc_....axp
```

### 搬到 Ubuntu 上离线用

```bash
# 在 Mac 上导出成一个文件
bash scripts/ax650-image/export.sh            # → ax650-images-V3.6.2.tar.zst
scp ax650-images-V3.6.2.tar.zst* ubuntu:/data/

# 在 Ubuntu 上还原
bash scripts/ax650-image/import.sh /data/ax650-images-V3.6.2.tar.zst
bash scripts/ax650-image/run.sh
```

或者直接在 Ubuntu 上从 `.axp` 重建（见下面「两种宿主」）。

## 两种宿主

`build.sh` 会自动选解包后端：

| 宿主 | 默认后端 | 说明 |
| --- | --- | --- |
| **macOS** | `docker` | 用特权容器做 `mount -o loop`（Docker Desktop 的 LinuxKit 内核支持） |
| **Ubuntu** | `native` | 有 root 就直接原生 loop mount，快得多，不需要工具镜像 |

强制指定：`--backend native` 或 `--backend docker`。

Docker 后端需要一个带 `mount` / `losetup` / `tar` 的镜像当工具容器，脚本会从本地已有的
镜像里自动挑（`docker-napcat-qce` → `ubuntu:24.04` → `ubuntu:22.04` → `debian:12`）。
一个都没有就用 `--tool-image ubuntu:22.04` 让它先 pull。

### x86_64 的 Ubuntu

镜像目标是 `linux/arm64`，在 x86_64 上跑要靠 QEMU 用户态模拟：

```bash
sudo apt install qemu-user-static binfmt-support
sudo systemctl restart systemd-binfmt      # 或者直接重启
docker run --rm --platform linux/arm64 ax650-env:V3.6.2 uname -m   # 应该输出 aarch64
```

`run.sh` 会自动检测并在缺失时报错。模拟下编译会明显变慢（大约 5~10 倍）。

## build.sh 参数

```
--axp PATH        固件包（也可用环境变量 AXP）
--envcfg PATH     EnvCfg 仓库，取 axcl_inc.tar / MVSDK / MVS
--tag TAG         镜像标签后缀，默认 V3.6.2
--work DIR        中间文件目录，默认 <脚本目录>/work
--stage STAGE     raw | tar | import | env（默认 env，即全流程）
--backend B       auto | native | docker
--tool-image IMG  特权工具容器镜像
--jobs N          编译并发
--rmcserial PATH  本地已有的 RMCVSerial tar（不联网时用）
--force           重做已有产物
```

分阶段跑很有用 —— 全流程十几分钟，卡在哪一步可以只重跑那一步：

```bash
bash scripts/ax650-image/build.sh --axp fw.axp --stage raw      # 只转换分区
bash scripts/ax650-image/build.sh --axp fw.axp --stage tar      # 到 ax650-rootfs.tar
bash scripts/ax650-image/build.sh --axp fw.axp --stage import   # 到 ax650-rootfs 镜像
bash scripts/ax650-image/build.sh --axp fw.axp --stage env      # 全流程
```

## 原理

`.axp` 就是一个 ZIP，里面装着 eMMC 各分区的 **Android sparse 格式** ext4 镜像：

| 成员 | 逻辑大小 | eMMC 挂载点 | 内容 |
| --- | --- | --- | --- |
| `ubuntu_rootfs_desktop_sparse.ext4` | 16 GiB | `/` | Ubuntu 22.04.5 aarch64 根文件系统 |
| `opt_sparse.ext4` | 1.9 GiB | `/opt` | Axera SDK demo、Qt 5.15.7 |
| `soc_sparse.ext4` | 384 MiB | `/soc` | AXCL 运行库 `libax_*.so`、内核模块 |
| `param_sparse.ext4` | 20 MiB | `/param` | AVS 标定参数 |

`/opt` `/soc` `/param` 在原厂固件里是**三个独立分区**（`/etc/fstab` 里的
mmcblk0p12 / p11 / p4），rootfs 里对应的只是空挂载点。容器没法挂载它们，所以要合回去：

```
unzip(流式) ──> sparse2raw.py ──> rootfs/opt/soc/param.raw
                                        │
                    ┌───────────────────┘
                    ▼
   loop mount 4 个分区，把 /opt /soc /param 并回根文件系统
   （macOS 在特权容器里做，Ubuntu 原生做）
                    │
                    ▼
              tar ──> docker import ──> ax650-rootfs:V3.6.2
                    │
                    ▼
            加 apt 依赖 + AXCL 头文件 + MVSDK + MVS + RMCVSerial
                    │
                    ▼
                    ax650-env:V3.6.2
```

`simg2img` 只是 Android sparse 转 raw 的工具，这里用纯 Python 实现（`sparse2raw.py`），
好处是**不依赖任何系统包**，macOS/Ubuntu 都能直接跑，而且把洞用 `lseek` 写出来，
16 GiB 的镜像在 APFS 上只占约 4.7 GiB（ext4 上同理）。

## 产物

两个镜像是**父子关系**，`ax650-env` 的第一层就是 `ax650-rootfs` 的那一层，**层是共享的**，
所以两个加起来只占 9.74 GB（不是 8.03 + 9.74）。

| 镜像 | 层数 | 说明 |
| --- | --- | --- |
| `ax650-rootfs:V3.6.2` | 1 | **原始的固件内容**。上科大 Magician 固件的完整 aarch64 根文件系统 |
| `ax650-env:V3.6.2` | 12 | 第 1 层 = 上面那层，再叠 11 层编译依赖和厂商 SDK。日常用这个 |

`ax650-rootfs` 相对固件做的改动**只有两处**，都是容器化必需的：

1. 把 `/opt`（mmcblk0p12）、`/soc`（mmcblk0p11）、`/param`（mmcblk0p4）三个独立分区的内容
   合并进根文件系统；各分区的 `lost+found` 未复制
2. 清了 `/var/log/*`、`/tmp/*`、`/root/.cache`

除此之外逐字节未动 —— 连 `rootfs` 里那 334 MB 的 `/var/cache/apt/archives` 都保留了。
真正"原始"的是那个 2.1 GB 的 `.axp` 文件本身。

`ax650-env` 里额外装了：

- apt：`gcc-11` / `g++-11` / `cmake` / `make` / `ninja` / `pkg-config` / `ccache`、
  `libboost-dev`、`libopencv-dev`、`libeigen3-dev`、`libusb-1.0-0`
- `/soc/include/` —— AXCL 头文件（来自 EnvCfg `sources/axcl_inc.tar`）
- `/usr/lib/aarch64-linux-gnu/libMVSDK.so` —— 迈德威视 MVSDK（主线相机后端）
- `/opt/MVS/` —— 海康 MVS（可选后端，`USE_HIKCAM=ON` 时用），已补 `.so` 软链
- `/usr/local/lib/libRMCVSerial.so` —— RMCVSerial V1.1.1

## 验证状态

**功能验证**（在 `public-release-2026` 工作树上实测）：

- `cmake -S . -B build -DINFERENCE_BACKEND=AXCL` 配置通过，
  找到 `MindVision MVSDK library: /usr/lib/aarch64-linux-gnu/libMVSDK.so`
- `cmake --build build -j10` 编译通过，产出 `build/auto-aim`（只有仓库自身的 warning）
- `source=test.avi` + `port=None` 跑起来：`MockDriver`、`sensor/video`、
  `preprocess`、`corner_refine`、`predict`、`planner` 全部正常构建并启动任务
- 两种解包后端都用合成的小分区跑过断言测试（三个分区合并、日志清理、`lost+found` 排除）

推理部分的实际表现是**软失败**，不会崩：

```text
Failed to open /proc/ax_proc/logctl
[AXCL] Init SYS failed.
[detect] model loaded
...
[AXCL] Inference requested before backend initialization completed.
```

`AXCL::ready` 一直是 `false`，每帧打印一次错误，返回空检测框，后面的链路照常跑。
所以**检测之外的每一级都可以在容器里调试**，只是拿不到真实检测结果。

## 已知限制

- **没有 NPU**。容器里没有 `/dev/axcl0`，也没有 `/proc/ax_proc/*`，AXCL 推理跑不起来，
  `SKD250526.axmodel` 没法执行。想在容器里看到检测结果，只能在 `detect/` 里自己加一个
  读日志或回放检测框的后端。
- **没有相机和串口**。`source=0` 和真实 `/dev/ttyS*` 都用不了，只能用
  `test.avi` + `MockDriver`。
- **`-march=native`**。根 `CMakeLists.txt` 用 `-march=native` 编译，容器里的
  "native" 是宿主虚拟 CPU，**编出来的二进制不要拷到 AX650 上跑**，那个要靠板子自己编译。
- 容器里默认是 `root`（macOS）或降权到你的 uid（Linux），板子上是 `axera`。

## 依赖

构建镜像需要：

- 固件包 `.axp`
- EnvCfg 仓库里的 `sources/{axcl_inc.tar, MVS_aarch.deb, mindvision_arm64_*.tar.gz}`
  （`--envcfg` 指定，或放在 `~/PHOENIX_auto_aim_AX650-EnvCfg`）
- 联网：一次 `apt-get`（装 OpenCV/Eigen/Boost）+ 拉一次 RMCVSerial 归档。
  完全离线的话用 `--rmcserial /path/to/rmcv_serial-V1.1.1.tar`，apt 部分则需要预先准备好 deb

装完之后镜像就是自包含的，**日常使用完全离线**。

## 中间文件

都在 `scripts/ax650-image/work/`（已 gitignore）：

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `rootfs.raw` | 5.9 GB | 16 GiB 逻辑，稀疏 |
| `opt.raw` | 1.2 GB | |
| `soc.raw` | 101 MB | |
| `param.raw` | 20 MB | |
| `ax650-rootfs.tar` | 5.3 GB | import 用，导完就没用了 |
| `env/sources/` | 68 MB | docker build 上下文 |

镜像建好后可以全删（约 13 GB），下次重建会重新生成：

```bash
rm -rf scripts/ax650-image/work/{*.raw,ax650-rootfs.tar,env/sources}
```

构建缓存也占不少，可以顺手清：

```bash
docker builder prune -f
```
