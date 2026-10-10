# AX650 离线调试容器 · 完整使用教程

从零开始，假设你刚开电脑、还没启动 Docker。

**macOS 和 Ubuntu 都适用** —— 两条路径的差别集中在第 1 节（怎么启动 Docker）和
[第 16 节](#16-在-ubuntu-上)，中间的编译、运行、调试步骤完全一样。

镜像是这台机器上已经建好的：

| 镜像 | 大小 | 用途 |
| --- | --- | --- |
| `ax650-env:V3.6.2` | 9.74 GB | **日常用这个**。上科大 Magician 固件的 Ubuntu 22.04 aarch64 根文件系统 + 编译依赖 + 厂商 SDK |
| `ax650-rootfs:V3.6.2` | 8.03 GB | **原始固件内容**（只合并了三个分区、清了日志）。它是 `ax650-env` 的第一层，**层共享，留着不多占盘** |

> Ubuntu 上没有这两个镜像？两条路：从 `.axp` 重建（[第 15 节](#15-重建镜像)），
> 或者从 Mac 直接搬（[16.2](#162-从-mac-搬镜像过去不重建)）。

---

## 1. 启动 Docker Desktop

手动拉起 Docker Desktop：

```bash
open -a Docker
```

然后等它就绪（第一次大概 30~60 秒，鲸鱼图标变绿）：

```bash
until docker info >/dev/null 2>&1; do printf '.'; sleep 2; done; echo ' Docker 就绪'
```

看到 `Docker 就绪` 就行。想确认一下：

```bash
docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
```

必须是 **`linux/arm64`**。如果显示 `linux/amd64`（比如你换成了远程 Docker 上下文），后面所有东西都会走 QEMU 模拟，非常慢，先 `docker context use desktop-linux` 切回来。

> **报 `Cannot connect to the Docker daemon`** = Docker Desktop 还没起来，回到上面 `open -a Docker` 再等。

---

## 2. 确认镜像还在

```bash
docker images | grep ax650
```

应该看到两行：

```
ax650-env:V3.6.2      ...   9.74GB
ax650-rootfs:V3.6.2   ...   8.03GB
```

**没有？** 说明镜像被清理了，跳到 [第 15 节](#15-重建镜像)重建。

---

## 3. 进容器

```bash
cd /Users/shisanliuhuo/ax650_auto_aim
bash scripts/ax650-image/run.sh
```

提示符变成这样就成了：

```
root@a1b2c3d4e5f6:/work#
```

`run.sh` 干了这些事，你不需要记：

| 参数 | 作用 |
| --- | --- |
| `-v <仓库>:/work` | 把 Mac 上的仓库挂进容器，**改代码直接在 Mac 上用编辑器改**，容器里立刻能看到 |
| `-w /work` | 工作目录就是仓库根目录 |
| `-e LD_LIBRARY_PATH=/soc/lib:/usr/local/lib` | AXCL 运行库和 RMCVSerial 的路径 |
| `-e MINDVISION_PATH` / `-e MVS_PATH` | 两个相机 SDK 的位置，CMake 靠它们找库 |

容器里是 **root**，板子上是 `axera`，这个差异后面会提到。

---

## 4. 编译

在容器的 `/work` 下：

```bash
cmake -S . -B build -DINFERENCE_BACKEND=AXCL
cmake --build build -j"$(nproc)"
```

配置阶段应该能看到关键这一行：

```
-- MindVision MVSDK library: /usr/lib/aarch64-linux-gnu/libMVSDK.so
-- Found OpenCV: /usr (found version "4.5.4")
```

编译阶段只有仓库自身的 warning（`pipeline.hpp` 里 `BasicTask` 前向声明那些），最后：

```
[100%] Linking CXX executable auto-aim
[100%] Built target auto-aim
```

产出 `build/auto-aim`（**这个文件名同时在 Mac 上能看到**）。

**编译要多久**（这台 Mac，10 核，实测）：

| 场景 | 耗时 |
| --- | --- |
| 首次全量 | **约 30 秒** |
| 改一个 `.cpp` 后增量 | **约 7 秒** |

比想象中快很多，因为容器是原生 aarch64，没有 QEMU 模拟。

---

## 5. 配置 launch.cfg 走离线视频

容器里没有相机也没有串口，必须切到离线模式。改 `launch.cfg` 的**两行**：

```diff
- source=0
+ source=test.avi
- port=/dev/ttyS4 # None(use MockDriver for testing) or port path like /dev/ttyACM0
+ port=None
```

- `source=0` → 表示用 MindVision 相机；改成 `test.avi` 就变成读仓库根目录的视频
- `port=<路径>` → 真实串口；`None` 会走 `MockDriver`，自己造下位机数据

在容器里改也行：

```bash
sed -i 's|^source=0|source=test.avi|; s|^port=.*|port=None|' launch.cfg
```

在 Mac 上用编辑器改也行，因为是同一个文件。

> ⚠️ `launch.cfg` 是你自己改过的文件（`git status` 里是 ` M`），改之前记得心里有数。跑完实机记得改回去。

---

## 6. 跑起来

```bash
./build/auto-aim
```

**正常的输出长这样**（前 20 行左右）：

```
00:00:000: <MSG>: open log file success!
00:00:006: <MSG>: CoordTransformer initialized.
00:00:006: <WARN>: [init] Using MockDriver (no hardware mode)
00:00:006: <MSG>: [TimedSerial] constructing with injected driver
00:00:006: <MSG>: [MockDriver] Initializing mock driver
00:00:006: <MSG>: [MockDriver] Sent initial attitude: yaw=0.00, pitch=0.00
00:00:006: <MSG>: [MockDriver] Sent initial status: enemy_color=0, speed=28.00
00:00:006: <MSG>: [EntryStage] construction completed
00:00:006: <MSG>: [sensor_submodule] constructing with video: test.avi
00:00:046: <MSG>: [sensor_submodule] video initialized
00:00:046: <MSG>: [preprocess] construction completed
00:00:046: <MSG>: [detect] constructing with model: asset/models/SKD250526.axmodel
Failed to open /proc/ax_proc/logctl
00:00:049: <ERR>: [AXCL] Init SYS failed.
00:00:049: <MSG>: [detect] model loaded
00:00:049: <MSG>: [Planner] construction completed
00:00:050: <MSG>: [init] all pipeline tasks registered successfully, system can start
00:00:050: <MSG>: [init] Starting all tasks...
00:00:050: <MSG>: [init] All tasks started successfully!
```

**后面会一直刷这个，这是正常的：**

```
00:00:115: <ERR>: [AXCL] Inference requested before backend initialization completed.
```

因为容器里没有 AX650 的 NPU，`AXCL::ready` 永远是 `false`，每帧返回空检测框。**它不会崩**，后面的 corner_refine、predict、planner 照常跑。

不想看这堆刷屏：

```bash
./build/auto-aim 2>&1 | grep -v "Inference requested before"
```

**停止**：`Ctrl+C`。

想跑固定时长并留一份日志：

```bash
timeout 60 ./build/auto-aim 2>&1 | tee /work/run.log
```

---

## 7. 看模块日志

`launch.cfg` 里每个模块有两个开关，**语义不一样，别搞混**：

| 开关 | 效果 |
| --- | --- |
| `xxx_log_text=true` | 模块自己的判断输出打到**终端**（检测阈值、跟踪状态、规划结果这类） |
| `xxx_log_file=true` | 模块的 `LOGM_F` 写进 **`log/<启动时间>.txt`** |

可用前缀：`entrystage` / `sensor` / `preprocess` / `detect` / `corner_refine` / `predictor` / `planner`。
另外 `sensor` / `preprocess` / `detect` / `corner_refine` / `predictor` / `planner` 还有 `xxx_show_image`，
**容器里别开**，没有 X server 会报错。

### 最有用的一招：流水线逐模块耗时

**耗时的分解走的是 `log_file`，不是 `log_text`**（`entrystage` 的实现里写死了 `config_.debug.log_file`）：

```bash
sed -i 's|^entrystage_log_file=false|entrystage_log_file=true|' launch.cfg
timeout 8 ./build/auto-aim >/dev/null 2>&1

# 日志文件名是启动时间，带冒号
ls log/
# 2026-10-10-16:31:35.txt

# 日志里有 ANSI 颜色码，先洗掉再看
sed 's/\x1b\[[0-9;]*m//g' log/*.txt | head -40
```

输出长这样（前几帧是预热，`total time cost` 会是 `-1 ms`）：

```
[EntryStage] recording frame index: 0
[EntryStage] total time cost: 33 ms
[EntryStage] start time: 1738593
[EntryStage] "Entry" 2μs
[EntryStage] "Sensor" 32487μs | gap: 0μs
[EntryStage] "Preprocess" 1146μs | gap: 0μs
[EntryStage] "Detect" 17μs | gap: 14μs
...
```

`"X" Nμs` 是这个子模块自己的耗时，`gap` 是它和上一个模块之间的空档。
**在容器里 `Sensor` 会异常大（读 avi 解码）、`Detect` 异常小（没推理）**，
所以耗时数据只能拿来看相对趋势和找自己代码里的瓶颈，别拿它当板上的性能数字。

日志文件会**一直追加**（实测 8 秒就 26000 行），记得跑完 `rm -rf log/`。

---

## 8. 改代码 → 重编 → 再跑

代码在 Mac 上，容器只是挂载。所以：

1. **在 Mac 上用你的编辑器改** `main.cpp` / `detect/` / `planner/` 等等
2. 回到容器（不用重启容器）：

```bash
cmake --build build -j"$(nproc)"
./build/auto-aim
```

CMake 会自动重新配置被改动文件涉及的子目录。

---

## 9. 用 gdb 打断点

**坑：根 `CMakeLists.txt` 用 `FORCE` 把构建类型锁死成 Release 了**，所以你传 `-DCMAKE_BUILD_TYPE=RelWithDebInfo` 会被静默忽略（我实测过，`CMakeCache.txt` 里还是 `Release`），编出来的二进制没有调试符号。

要调 gdb，先改 `CMakeLists.txt` 第 18 行：

```diff
-set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build." FORCE)
+set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Choose the type of build." FORCE)
```

然后**必须删掉 build 目录重配**（CACHE 变量不会自己更新）：

```bash
rm -rf build
cmake -S . -B build -DINFERENCE_BACKEND=AXCL
cmake --build build -j"$(nproc)"
gdb ./build/auto-aim
```

gdb 里能用的（我在容器里实测过断点、看变量都正常）：

```gdb
break detect::DetectSubModule::process      # 下断点
run                                          # 跑
bt                                           # 调用栈
print det.size()                             # 看检测框数量
continue / next / step / finish              # 单步
info threads                                 # 看各个 pipeline 线程
```

只有一个无害警告 `Error disabling address space randomization: Operation not permitted`，忽略即可。

> 调完记得把 `CMakeLists.txt` 改回 `Release`，不然会影响你提交。

---

## 10. 不进交互 shell，直接跑一条命令

```bash
cd /Users/shisanliuhuo/ax650_auto_aim

# 重新编译
bash scripts/ax650-image/run.sh -c 'cmake --build build -j$(nproc)'

# 跑并过滤噪音
bash scripts/ax650-image/run.sh -c './build/auto-aim 2>&1 | grep -v "Inference requested" | head -40'

# 检查环境
bash scripts/ax650-image/run.sh -c 'pkg-config --modversion opencv4; ls /soc/lib | head'
```

`run.sh` 看到第一个参数是 `-` 开头，会自动补 `/bin/bash`，所以你写 `-c '...'` 就行。

想挂别的目录：

```bash
REPO=/path/to/other/repo bash scripts/ax650-image/run.sh
```

---

## 11. 退出容器

```bash
exit
```

`run.sh` 用的是 `--rm`，退出即销毁容器，**但 `/work` 在 Mac 上，代码和 `build/` 一点都不会丢**。下次 `run.sh` 又是一个干净容器（只有 `build/` 是复用的）。

---

## 12. 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `Cannot connect to the Docker daemon` | Docker Desktop 没启动 → `open -a Docker` |
| `docker: unknown command: docker buildx` | 你手动设过 `DOCKER_CONFIG` 指向别处 → `unset DOCKER_CONFIG` |
| `[AXCL] Init SYS failed` + 一直刷 `Inference requested before...` | **正常**，容器里没有 NPU |
| `libMVSDK.so not found` | 环境变量没传进去 → 用 `run.sh` 进容器，别用裸 `docker run` |
| `not defined env: MVS_PATH` | 同上，`run.sh` 里带了 |
| 编译报 `-march=native` 相关错误 | 正常，容器虚拟 CPU 支持的特性集和板子不同，见第 13 节 |
| `git status` 里多了 `build/` | `build/` 已在 `.gitignore` 里，不会误提交 |
| 磁盘报警 | 见第 14 节清理 |

---

## 13. 容器 ≠ 板子（重要）

这个容器是拿来**验证逻辑和编译**的，不是 AX650 的替代品：

| 能力 | 容器里 | AX650 板子上 |
| --- | --- | --- |
| 编译整条链路 | ✅ | ✅ |
| 视频回放 + MockDriver | ✅ | ✅ |
| 取流 / 预处理 / 后处理 / PnP / 跟踪 / 规划 | ✅ 都能跑 | ✅ |
| **NPU 推理（`SKD250526.axmodel`）** | ❌ 没有 `/dev/axcl0` | ✅ |
| **真实检测框** | ❌ 每帧返回空 | ✅ |
| MindVision / 海康相机 | ❌ 没有 USB 设备 | ✅ |
| 真实串口 `/dev/ttyS*` | ❌ | ✅ |
| GUI 显示（`*_show_image`） | ❌ 没有 X | ✅ |
| 用户身份 | `root` | `axera` |
| 编译目标 | `-march=native` = Apple 虚拟 CPU | `-march=native` = Cortex-A55 |

**所以两条铁律：**

1. **容器里编出来的 `auto-aim` 不要拷到板子上跑** —— `-march=native` 编的是 Mac 的 ARM 核，指令集对不上。板子上必须自己重编。
2. **检测相关的逻辑别在容器里调** —— 你看到的是空框，任何依赖检测框的判断（跟踪初始化、PnP、目标选择）都拿不到真实输入。这些只能上板子调。

---

## 14. 磁盘维护

现在 `scripts/ax650-image/work/` 里有 **13 GB 中间产物**，镜像建好之后就没用了：

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `rootfs.raw` | 5.9 GB | 根文件系统 raw，重建镜像时才需要 |
| `ax650-rootfs.tar` | 5.3 GB | import 用的 tar，已经 import 完了 |
| `opt.raw` | 1.2 GB | |
| `soc.raw` | 101 MB | |
| `param.raw` | 20 MB | |

**镜像已经建好、暂时不打算重建**的话，直接删：

```bash
cd /Users/shisanliuhuo/ax650_auto_aim
rm -rf scripts/ax650-image/work/{*.raw,ax650-rootfs.tar}
```

以后想重建，跑 `bash scripts/ax650-image/build.sh` 会从 `.axp` 重新生成（约 10 分钟）。

Docker 侧的构建缓存也占了 10 GB，可以清：

```bash
docker builder prune -f               # 清 build cache，这里有 ~4 GB 可回收
# 注意：删 ax650-rootfs 省不出 8 GB —— 它那一层和 ax650-env 共享，UNIQUE SIZE 只有 852 B
# docker image rm ax650-rootfs:V3.6.2   # 真想删再删，省不了多少空间
```

查一下当前占用：

```bash
docker system df
```

---

## 15. 重建镜像

改了 `env/Dockerfile`（比如想加 `valgrind`、`strace`）或者换了固件包之后：

```bash
cd /Users/shisanliuhuo/ax650_auto_aim
bash scripts/ax650-image/build.sh --axp /path/to/AX650_emmc_....axp
```

完整流程约 10 分钟：解 `.axp` → 转 raw → loop mount 合并 `/opt` `/soc` `/param` → `docker import` → `docker build`。

可以分阶段跑，卡住时只重跑那一步：

```bash
bash scripts/ax650-image/build.sh --axp fw.axp --stage raw      # 只转换分区（约 2 分钟）
bash scripts/ax650-image/build.sh --axp fw.axp --stage tar      # 到 ax650-rootfs.tar
bash scripts/ax650-image/build.sh --axp fw.axp --stage import   # 到 ax650-rootfs 镜像
bash scripts/ax650-image/build.sh --axp fw.axp --stage env      # 全流程（默认）
```

**构建时需要联网**（apt 装 OpenCV/Eigen/Boost，拉 RMCVSerial）。装完之后镜像就是自包含的，日常使用完全离线。

常用参数（完整列表 `bash scripts/ax650-image/build.sh --help`）：

| 参数 | 作用 |
| --- | --- |
| `--axp PATH` | 固件包 |
| `--envcfg PATH` | EnvCfg 仓库（取 axcl_inc.tar / MVSDK / MVS） |
| `--tag TAG` | 换标签，默认 `V3.6.2` |
| `--work DIR` | 换中间文件目录 |
| `--backend auto\|native\|docker` | 解包后端，默认 macOS 用 docker、Linux 用 native |
| `--tool-image IMG` | 特权工具容器镜像 |
| `--rmcserial PATH` | 本地已有的 RMCVSerial tar |
| `--force` | 重做已有产物 |

---

## 16. 在 Ubuntu 上

同一套脚本在 Ubuntu 上直接用，`build.sh` 会自动换后端。

### 16.1 从固件重建（推荐，不用传大文件）

```bash
sudo apt update
sudo apt install -y docker.io python3        # 或者用 Docker 官方源
sudo usermod -aG docker "$USER" && newgrp docker

# .axp 和 EnvCfg 仓库拷过来
bash scripts/ax650-image/build.sh \
    --axp ~/fw/AX650_emmc_ubuntu_rootfs_desktop_V3.6.2_*.axp \
    --envcfg ~/PHOENIX_auto_aim_AX650-EnvCfg
```

Ubuntu 上会走 **native** 后端：直接 `mount -o loop`，不经过容器，比 macOS 快。需要 root
（脚本里用 `sudo`，会提示输密码）。

### 16.2 从 Mac 搬镜像过去（不重建）

```bash
# Mac 上
bash scripts/ax650-image/export.sh
# → ax650-images-V3.6.2.tar.zst（通常 2~4 GB）+ .sha256

scp ax650-images-V3.6.2.tar.zst* ubuntu:/data/

# Ubuntu 上
bash scripts/ax650-image/import.sh /data/ax650-images-V3.6.2.tar.zst
```

`docker save` 一次给两个镜像时会自动去重共享层，所以 `ax650-rootfs` 那 8 GB 只出现一次。

### 16.3 如果是 x86_64 的 Ubuntu

镜像目标是 `linux/arm64`，x86_64 上要靠 QEMU 用户态模拟：

```bash
sudo apt install qemu-user-static binfmt-support
sudo systemctl restart systemd-binfmt        # 或者直接重启

# 验证
docker run --rm --platform linux/arm64 ax650-env:V3.6.2 uname -m   # 要输出 aarch64
```

`run.sh` 会自动检测，没装 QEMU 会直接报错告诉你怎么装。模拟下编译大约慢 5~10 倍。

### 16.4 和在 Mac 上的区别

| | macOS | Ubuntu |
| --- | --- | --- |
| build.sh 后端 | `docker`（特权容器） | `native`（原生 mount，更快） |
| 需要 sudo | 不需要 | 需要（native 后端） |
| run.sh 容器内用户 | `root`（Docker Desktop 映射成你） | **降权成你的 uid**，`build/` 不会变 root 属主 |
| 启动 Docker | `open -a Docker` | `sudo systemctl start docker` |
| x86_64 宿主 | 不适用 | 需要 `qemu-user-static` |

Linux 上如果不想降权（比如需要写 `/soc` 之类），用 `AX650_AS_ROOT=1 bash scripts/ax650-image/run.sh`。

---

## 附：速查卡

```bash
# —— macOS ——
open -a Docker && until docker info >/dev/null 2>&1; do sleep 2; done
# —— Ubuntu ——
sudo systemctl start docker

# 构建（macOS / Ubuntu 通用）
bash scripts/ax650-image/build.sh --axp /path/to/AX650_emmc_*.axp

# 进容器（仓库挂在 /work）
cd /Users/shisanliuhuo/ax650_auto_aim && bash scripts/ax650-image/run.sh

# 首次编译
cmake -S . -B build -DINFERENCE_BACKEND=AXCL && cmake --build build -j"$(nproc)"

# 切离线模式（只做一次）
sed -i 's|^source=0|source=test.avi|; s|^port=.*|port=None|' launch.cfg

# 跑
./build/auto-aim 2>&1 | grep -v "Inference requested"

# 非交互
bash scripts/ax650-image/run.sh -c 'cmake --build build -j$(nproc)'

# 搬到别的机器
bash scripts/ax650-image/export.sh
bash scripts/ax650-image/import.sh ax650-images-V3.6.2.tar.zst

# 退出
exit
```
