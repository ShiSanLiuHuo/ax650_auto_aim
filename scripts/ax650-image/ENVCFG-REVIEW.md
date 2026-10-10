# 上科大 AX650 镜像 & EnvCfg 审计报告

审计日期：2026-10-10
方法：把 `.axp` 固件转成 Docker 镜像后，在纯净的 `ax650-rootfs:V3.6.2` 里**原样跑 `AutoInstall.sh`** 两轮（轮 A 保持原配置，轮 B 只把 apt 源换成清华 TUNA），逐步骤验证产物。

---

## 一、镜像是哪一个

**结论：你 Downloads 里那个 `.axp` 就是上科大开源的 Magician 板固件，也就是 EnvCfg 文档里说的"上科大定制 AX650 镜像"。**

> ⚠️ 本节初版结论写错了（当时把它当成 Axera 的包、判定"无上科大痕迹"），已更正。错因见本节末尾。

### `Magician` 是上海科技大学自研开发板的名字

| 证据 | 内容 |
| --- | --- |
| RoboMaster 论坛帖标题 | [【RM2026-AX650自瞄部署平台硬件开源】上海科技大学-magician](https://bbs.robomaster.com/article/1883967) |
| 同团队另一帖 | [【RM2026-AX650自瞄视觉项目开源】上海科技大学-magician](https://bbs.robomaster.com/article/1883871) |
| `.axp` 的实际下载来源 | 百度网盘分享目录 `Magician_AX650X载板方案_EMMC_发版固件_1.0`（macOS `kMDItemWhereFroms` 元数据） |
| 本地同名目录 | `~/Downloads/Magician_AX650X载板方案_EMMC_发版固件_1.0/`（空的，创建于下载前 2 分钟） |
| u-boot / fdl2 标识串 | `Magician Axera AX650 OVAI System` = 上科大 Magician 板 + Axera AX650 OVAI 平台 |
| EnvCfg 作者邮箱 | commit `637b16b` 作者 `xuyue2023@shanghaitech.edu.cn` |

`.axp` 文件名 `..._V3.6.2_20250603154858_20260311084521` 有两个时间戳，是 **2026-03-11 基于 Axera V3.6.2 重新打包**的；rootfs 里 `/etc/fstab` 的 mtime 也正是 2026-03-11。

### 配套性判据

| 证据 | 结果 |
| --- | --- |
| EnvCfg README 要求 `insmod /lib/modules/5.15.73/rtl8xxxu.ko` | 镜像里有 `/lib/modules/5.15.73/`，257 MB 模块树 ✅（但该 `.ko` 本身不存在，见问题 5） |
| EnvCfg 声明"面向 AX650 板端（Ubuntu 22.04 aarch64）" | 镜像 rootfs 是 Ubuntu 22.04.5 LTS aarch64 ✅ |
| 用户 `axera`（uid 1000） | 存在，`/etc/rc.local` 里有 `chown axera:axera /home/axera/` ✅ |
| AXCL 运行库 | `/soc/lib/libax_*.so` 齐全 ✅ |

### 镜像里确实没有 `shtech` / 上科大 字样 —— 因为这块的品牌是 Magician

| 检查项 | 结果 |
| --- | --- |
| `/etc/hwrevision` | `AX650_emmc 1.0`（沿用 Axera 的标识格式） |
| 全盘 grep `shtech / shanghaitech / Astra / 上科大` | `/etc`、`/opt`、`/usr/local`、`/root`、`/home` 里都没有 |
| `/etc/rc.local` | Axera 驱动加载脚本（`auto_load_all_drv.sh`、`pcie_load_drv.sh`） |
| 设备树 `AX650_emmc_signed.dtb` | 全 `axera,*` 兼容串 |
| 预置 WiFi 连接 | 无 |

固件是在 Axera 参考设计上做的板级适配，rootfs 层没有改名，上科大的标识只体现在**板名 `Magician`** 上。

### 初版错在哪

我按 `shtech / shanghaitech / 上科大` 去 grep，没搜到就下了"无上科大痕迹"的结论；**实际上看到了 `Magician Axera AX650 OVAI System`，却把它当成了某个第三方载板厂商**，没有去查这个名字是谁的。查一下就知道 `Magician` = 上海科技大学。有证据在手却做了错误归属，这是本次审计最该记的教训。

---

## 二、`PHOENIX_auto_aim_AX650-EnvCfg` 的身份

它**不是独立写的**，而是上科大 EnvCfg 的 fork：

```
上游  Astra-Whale/SHtech_auto_aim_AX650-EnvCfg   for_2026_open_source @ 161db38 (2026-05-04)
你的  ShiSanLiuHuo/PHOENIX_auto_aim_AX650-EnvCfg  for_2026_open_source @ dfcb76a (2026-09-07)  = 上游 + 1 commit
```

`dfcb76a` 只做了一件事：把 `git clone .../SHtech_auto_aim` 改成 `git clone .../SHtech_auto_aim.git auto-aim`，修掉"clone 出来的目录名和后面 `cd auto-aim` 对不上"的问题。

**⚠️ 但真正把 MVS 换成 MindVision 的改动还没提交：**

```
$ git status --short
 M AutoInstall.sh                 ← MVS → MindVision、引号修正、clone 目标改成本仓库
 M README.md
?? sources/mindvision_arm64_v2.1.0.37.tar.gz   ← 未跟踪
```

也就是说：仓库里 HEAD 的版本还是海康 MVS 版本，"MindVision 版"只存在于你的工作区。

---

## 三、实测结果

### 轮 A：完全按原样跑（只补了 Docker 专属的 `/tmp` 权限）

| 步骤 | 结果 | 证据 |
| --- | --- | --- |
| 1. `apt update` + `apt install` | ❌ **全部失败** | `Err: http://mirrors.aliyun.com/ubuntu-ports ... 403 Forbidden` ×4，`E: Unable to fetch some archives` |
| 2. `tar -xvf sources/axcl_inc.tar -C /soc` | ✅ | `/soc/include` 55 个头文件 |
| 3. MindVision MVSDK | ✅ | 库、头文件、2 条 udev 规则、`mvusb_dev` 组、`MINDVISION_PATH` 全部落盘 |
| 4. RMCVSerial | ❌ | **步骤 1 的连锁反应**：`Could NOT find Boost (missing: Boost_INCLUDE_DIR)` → `No targets specified and no makefile found` |
| 5. auto-aim | （跳过） | |
| **脚本退出码** | **0** | 五步里两步彻底失败，仍然返回 0 |

### 轮 B：只把 apt 源换成清华 TUNA

| 步骤 | 结果 | 证据 |
| --- | --- | --- |
| 1. `apt update` + `apt install` | ✅ | 181 个新包 + 16 个升级，143 MB；`/usr/include/eigen3`、`cmake/opencv4`、`libopencv_core.so`、`/usr/include/boost` 全部到位 |
| 2. AXCL 头文件 | ✅ | 55 个 |
| 3. MindVision MVSDK | ✅ | `libMVSDK.so` 13.4 MB |
| 4. RMCVSerial | ✅ | `libRMCVSerial.so` 921 KB，`Found Boost: ... 1.74.0` |
| 5. auto-aim | ❌ **必然失败** | 见下 |
| **脚本退出码** | **0** | 仍然返回 0 |

**第 5 步的失败原文：**

```
Cloning into 'auto-aim'...
-- Found OpenCV: /usr (found version "4.5.4")
CMake Error at sensor/CMakeLists.txt:19 (message):
  not defined env: MVS_PATH
make: *** No targets specified and no makefile found.  Stop.
```

**根因** —— `git clone` 下来的仓库还是旧版：

```
$ grep -n "USE_MINDVISION\|USE_HIKCAM" /root/auto-aim/CMakeLists.txt
16:option(USE_HIKCAM "Build with HikCAM Lib" ON)
```

GitHub 上 `ShiSanLiuHuo/ax650_auto_aim` 的公开分支 `public-release-2026` 的 `CMakeLists.txt` **没有 `USE_MINDVISION` 选项**。EnvCfg 传的 `-DUSE_MINDVISION=ON` 被 CMake 当成未使用变量静默忽略，`USE_HIKCAM` 保持默认 `ON`，于是 `sensor/CMakeLists.txt:19` 去检查 `MVS_PATH` 环境变量 —— 而 EnvCfg 已经不再安装海康 MVS、也不设置这个变量 —— 直接 `FATAL_ERROR`。

你本地工作区有未提交的 `sensor/mindvision/` + `CMakeLists.txt` 改动，所以**本地能编**（已实测通过）；但 EnvCfg 第 5 步 clone 的是 GitHub 上的旧版，**必失败**。

---

## 四、问题清单

### 🔴 严重

**1. apt 源不可用时全盘静默失败，退出码仍是 0**

`AutoInstall.sh` 没有 shebang、没有 `set -e`、没有任何错误分支。第一行 `apt update` 403 之后脚本继续往下跑，最后打印"安装完成"，退出码 0。用户**只能靠事后手查**才知道 OpenCV/Eigen/Boost 根本没装上。

`mirrors.aliyun.com` 在当前网络下对 `ubuntu-ports` 返回 403（清华 TUNA 正常）。

**2. 第 5 步与它 clone 的仓库不匹配**

见上。`-DUSE_MINDVISION=ON` 对 `public-release-2026` 无效。

**3. 公开 git 历史里有明文账号密码**

```
$ git log --all --oneline -S "cvdeployer"
6d6a7c4 For AX650N                                   ← 引入
dfcb76a fix: clone auto-aim into expected directory  ← 删除

$ git show 6d6a7c4 | grep cvdeployer
+    echo "deploying account username:cvdeployer password:robomaster"
```

`dfcb76a` 只是把它从**最新代码**里删掉了，`git show 6d6a7c4` 仍然能翻出来。**上游 `Astra-Whale` 的仓库同样有这条历史。** 凭据需要轮换，历史需要清理（`git filter-repo`）。

### 🟡 中等

**4. `~/.bashrc` 里的 `LD_LIBRARY_PATH` 是无条件写的**

```bash
cd build
cmake ..
make -j
sudo make install
...
echo 'export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH' >> ~/.bashrc
echo 'serial libs installation complete'      # ← cmake/make 全失败也照打印
```

轮 A 里 cmake 和 make 都失败了，`.bashrc` 里照样多出这一行，输出照样是"serial libs installation complete"。

**5. README 里的开机加载指令在这版镜像上是错的**

```bash
insmod /lib/modules/5.15.73/rtl8xxxu.ko
```

`/lib/modules/5.15.73/` 下**没有 `rtl8xxxu.ko`**，`modules.dep` 里没有，`modules.builtin.modinfo`（内建模块清单）里也没有：

```bash
$ find / -iname "*8xxxu*" -not -path "/proc/*"
/usr/src/linux-headers-5.15.0-100/drivers/net/wireless/realtek/rtl8xxxu   # 只有内核源码头的目录

$ grep -a -o "rtl8xxxu[a-z_]*" /lib/modules/5.15.73/modules.builtin.modinfo | wc -l
0
$ grep -a -o "^[a-z0-9_]\{6,\}" /lib/modules/5.15.73/modules.builtin.modinfo | head -1
sha1_ce      # 对照：这个清单是可读的，搜法有效
```

同一个 realtek 目录下只有 `rtl818x` / `rtlwifi` / `rtw88` 三个子目录，USB 无线驱动是 `rtl8187.ko`、`rtl8192cu.ko`、`mt76x02-usb.ko` 这些。

**所以 `insmod /lib/modules/5.15.73/rtl8xxxu.ko` 在这份镜像上必然报 `No such file or directory`，而且驱动既不是模块也没编进内核。**

这条 README 是上科大团队自己写的，用来指导自己发行的镜像 —— 属于**自相矛盾**。可能的原因：写文档时用的是别的内核版本，或者这块板的 WiFi 方案后来改过（换成 `rtw88` 系列）而 README 没跟着更新。

### 🟢 轻微

**6. Jetson 残留提示**

```bash
echo 'Please reboot and check status of ttyTHS1 after whole installation complete'
```

`ttyTHS1` 是 NVIDIA Jetson 的串口名。环境配置仓库的历史里确实有一条 `e9cfb6e update AutoInstall Script to adapt JetPack5.1.3` —— 这个脚本是从 Jetson 版改过来的。AX650 上应该是 `/dev/ttyS*`（你 `launch.cfg` 里用的是 `/dev/ttyS4`）。

**7. `udevadm trigger` 在容器里必然报错**（真机上无此问题，仅说明脚本对环境的假设）

```
Failed to send reload request: No such file or directory
breakpoint: Failed to write 'change' to '/sys/devices/breakpoint/uevent': Read-only file system
```

脚本已经用 `|| true` 吞掉了，无害。

**8. Docker 专属：`/tmp` 权限**

导出后的 rootfs 里 `/tmp` 是 `0755`（真机上是 tmpfs `1777`），导致 `apt` 降权到 `_apt` 后写不了临时文件：

```
E: Couldn't create temporary file /tmp/apt.conf.XXX for passing config to apt-key
```

**这不是 EnvCfg 的 bug**，是我这边容器化引入的，已用 `chmod 1777 /tmp` 绕开。真机上不会遇到。

---

## 五、修复建议

### 最小改动（让脚本在板子上可靠）

```diff
+#!/usr/bin/env bash
+set -euo pipefail
+
-apt update
-apt install -y gcc g++ cmake libboost-dev libopencv-dev libeigen3-dev libusb-1.0-0
+if ! apt update; then
+    echo '默认源不可用，切换到清华 TUNA'
+    sed -i 's|mirrors\.aliyun\.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list
+    apt update
+fi
+apt install -y gcc g++ cmake libboost-dev libopencv-dev libeigen3-dev libusb-1.0-0
```

第 5 步二选一：

- **A（推荐，不依赖上游）**：删掉 clone，改成编译本地目录
  ```bash
  cd ~/ax650_auto_aim
  cmake -S . -B build -DINFERENCE_BACKEND=AXCL -DUSE_MINDVISION=ON
  cmake --build build -j4
  ```
- **B**：先把 `sensor/mindvision/` 和 `CMakeLists.txt` 的 `USE_MINDVISION` 改动推到 GitHub，再让脚本 clone。

RMCVSerial 那段把 `echo 'export LD_LIBRARY_PATH=...'` 移到 `make install` 成功之后：

```diff
-sudo make install
-cd ../..
+sudo make install || { echo 'RMCVSerial 安装失败'; exit 1; }
+cd ../..
```

### README 修正

- 删掉或改写 `insmod rtl8xxxu.ko` 那一段（模块不存在）
- `ttyTHS1` → `/dev/ttyS*`
- 补一句"apt 源不可用时先换源"

### 安全

`cvdeployer / robomaster` 需要轮换，并用 `git filter-repo` 从历史里清掉（fork 和上游都要处理）。

---

## 六、复现方法

```bash
# 轮 A：原样
docker run --rm --platform linux/arm64 \
  -v /Users/shisanliuhuo/PHOENIX_auto_aim_AX650-EnvCfg:/envcfg:ro \
  ax650-rootfs:V3.6.2 bash -c '
    chmod 1777 /tmp /var/tmp; mkdir -p /run/lock; chmod 1777 /run/lock
    cp -a /envcfg /tmp/envcfg && cd /tmp/envcfg
    printf "\nn\ns\n" | bash AutoInstall.sh'

# 轮 B：只换源
#   sed -i "s|mirrors.aliyun.com|mirrors.tuna.tsinghua.edu.cn|g" /etc/apt/sources.list
#   再跑同样的命令
```

原始日志：`scripts/ax650-image/envcfg-test.log`（轮 A，72 KB）、`scripts/ax650-image/envcfg-test2.log`（轮 B，98 KB）
