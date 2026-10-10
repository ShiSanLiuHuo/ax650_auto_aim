# 依赖与示范资产

这份文档说明 `auto-aim` 当前实现实际使用的系统依赖、外部库、内置组件和示范资产。它补充根目录 `README.md`，不替代 EnvCfg 安装脚本，也不把未充分维护的后端描述为主线能力。

## 支持范围

| 类别 | 当前定位 | 说明 |
| --- | --- | --- |
| AXCL | 主线 | 面向 AX650，使用 `asset/models/SKD250526.axmodel` |
| TensorRT | 保留后端 | 需要 CUDA 和 TensorRT，维护与验证不充分 |
| MIGraphX | 保留后端 | CMake 取值为 `ONNX`，使用 `SZU0526` 模型，维护与验证不充分 |
| 视频离线模式 | 示范模式 | 使用 `test.avi` 和 `MockDriver`，不需要连接相机或下位机 |
| `tools/` | 辅助工具 | 用于标定、日志分析和算法实验，不属于主流程支持面 |

## 依赖总览

| 依赖 | 代码位置或来源 | 使用模块 | 准备方式 | 当前边界 |
| --- | --- | --- | --- | --- |
| OpenCV | 系统包 | 全局图像和矩阵处理 | `find_package(OpenCV)` | 版本未锁定 |
| Eigen3 | 系统包 | 坐标变换、滤波和规划 | `find_package(Eigen3)` | 版本未锁定 |
| Boost | RMCVSerial 的构建依赖 | `timedserial` 间接使用 | EnvCfg 构建 RMCVSerial 时安装 | 主工程没有独立的 Boost 检查 |
| AXCL | AX650 基础镜像和 `/soc` | `detect/AXCL` | EnvCfg 解包 AXCL 头文件 | 运行库不在 `auto-aim` 仓库中 |
| MindVision MVSDK | `sensor/mindvision` 头文件和 EnvCfg 离线包 | `sensor` | EnvCfg 安装 MVSDK 并设置 `MINDVISION_PATH` | 主线相机后端，包内版本为 `linuxSDK_V2.1.0.37` |
| Hikvision MVS | `sensor/hikcam` 头文件和 EnvCfg 安装包 | `sensor`（`USE_HIKCAM=ON`） | 手动安装 MVS 并设置 `MVS_PATH` | 可选后端；内容指向 MVS 2.1.0，但包元数据不一致 |
| RMCVSerial | 公开 GitLab `V1.1.1`，commit `56471959` | `timedserial/UartIMU` | EnvCfg 下载、构建并安装到 `/usr/local` | 压缩包版本与 CMake 内部版本不一致 |
| TinyMPC | `planner/tinympc`，上游 commit `7cecb25e` | `planner` | 随仓库构建 `tinympcstatic` | 本地保留两处定制 |
| CUDA、TensorRT | 系统运行时 | `detect/TensorRT` | 目标设备自行准备 | 只在 `INFERENCE_BACKEND=TRT` 时使用 |
| ROCm、MIGraphX | `/opt/rocm` | `detect/ONNX` | 目标设备自行准备 | 只在 `INFERENCE_BACKEND=ONNX` 时使用 |

主线构建默认启用 `USE_MINDVISION`。编译阶段会包含 `sensor/mindvision`，运行阶段由 `launch.cfg` 的 `source` 选择相机或 `test.avi`。离线模式不需要相机，但编译仍要能找到 `libMVSDK.so`；只跑视频输入时可以用 `-DUSE_MINDVISION=OFF -DUSE_HIKCAM=OFF` 完全去掉相机后端。

即使 `port=None` 使用 `MockDriver`，`timedserial` 仍会编译 `UartDriver` 并链接 RMCVSerial。离线模式仍需准备 RMCVSerial 的头文件和共享库。

## EnvCfg 的职责

[PHOENIX AX650 环境配置仓库](https://github.com/ShiSanLiuHuo/PHOENIX_auto_aim_AX650-EnvCfg)面向上科大定制 AX650 镜像，是从上游 [Astra-Whale/SHtech_auto_aim_AX650-EnvCfg](https://github.com/Astra-Whale/SHtech_auto_aim_AX650-EnvCfg) 分出的 fork。两边都只有 `for_2026_open_source` 一个公开分支，没有 tag；fork 的分叉点上游 HEAD 为 `161db3897e7098e800f9d654af197f7f5acb106c`，fork 在该分支上追加了 `dfcb76a`（修正 auto-aim 的 clone 目录）、相机 SDK 换成 MindVision，并把 clone 目标改成本仓库。`AutoInstall.sh` 执行以下工作：

- 安装 GCC、CMake、OpenCV、Eigen3 和 Boost 等通用构建依赖
- 将 `sources/axcl_inc.tar` 解包到 `/soc`，补充 AXCL 头文件
- 解包 `sources/mindvision_arm64_v2.1.0.37.tar.gz`，安装 MindVision MVSDK 并设置 `MINDVISION_PATH`
- 从公开 GitLab 下载 RMCVSerial `V1.1.1`，构建后安装到 `/usr/local`
- clone `ShiSanLiuHuo/ax650_auto_aim`，并以 `-DINFERENCE_BACKEND=AXCL -DUSE_MINDVISION=ON` 构建

AXCL 运行库、AX650 固件和设备侧驱动由基础镜像或目标设备提供。EnvCfg 不会把这些运行时内容转换为通用 Ubuntu 环境。

脚本文件没有 shebang，也没有错误中止策略。除新增的 MindVision 离线包自带 `VERSION.txt` 和 SHA-256 记录外，其余下载内容仍没有统一的 commit、版本清单或校验和。重复执行时，已有的 clone、build 目录和用户环境变量可能产生冲突。脚本历史还包含部署凭据。内部使用时应把凭据轮换和历史清理列为独立任务，文档不展示凭据内容。

MindVision 的安装并非只复制库文件。EnvCfg 会把 `88-mvusb.rules` 和 `99-mvusb.rules` 复制到 `/etc/udev/rules.d/`，把头文件复制到 `/usr/include/mindvision/`，把 `libMVSDK.so` 复制到 `/usr/lib/aarch64-linux-gnu/`（目录不存在时退回 `/usr/lib`），最后执行 `ldconfig`。udev 规则负责放开 USB 相机设备节点权限，需要重新插拔相机或重启后生效。`99-mvusb.rules` 引用 `mvusb_dev` 用户组，脚本会在该组缺失时创建。

fork 已把三处跳过提示的未加引号判断改成 `[ "${skip}" = 's' ]`，直接回车不会再触发 shell 判断错误；上游 `161db38` 版本仍有该问题，其余脚本结构（无 shebang、无错误中止策略）未改动。AXCL 头文件包仅用于目标环境。其 `ax_isp_version.h` 标识 `AX650` 和 ISP 版本 `3.8.3`，头部包含 Axera 版权和复制限制说明。

环境准备完成后，重新加载环境变量，再在 `auto-aim` 根目录构建：

```bash
source ~/.bashrc
cmake -S . -B build -DINFERENCE_BACKEND=AXCL
cmake --build build -j4
```

## 外部库

### RMCVSerial

`timedserial/UartIMU/uart_driver.hpp`直接使用 `drivers::RMCVSerial`。EnvCfg 当前从公开 GitLab 的 `V1.1.1` 标签下载源码，并通过 CMake 安装共享库和头文件。

当前审计结果：

- 源码使用 Boost.Asio，C++ 标准设置为 C++14
- `V1.1.1` 标签对应 commit `56471959e36ef46d29517b5b34c4c3dad439c392`
- 压缩包文件没有独立 README、LICENSE 或 NOTICE
- 头文件和部分源文件带有 Apache 2.0 许可证说明，并列出 LeoDrive、Autoware Foundation 和 Trimble 的版权信息
- CMake 项目内部版本仍写为 `1.0.0`，与下载标签 `V1.1.1` 不一致
- CMake 生成的版本文件把 `RMCVSerial_VERSION` 当作字面量版本，不能提供可靠的 package 版本判断
- `timedserial` 通过链接器名称 `RMCVSerial` 查找安装结果，没有使用导出的 CMake package 配置
- 内部仓库已有 `V1.2.0` 标签，当前 EnvCfg 仍固定使用 `V1.1.1`

当前依赖版本固定为 `V1.1.1`。后续资料整理仍需补齐源 commit、许可证文件和第三方声明。

### MindVision MVSDK

依赖来源是迈德威视官方 Linux SDK `linuxSDK_V2.1.0.37`。`sensor/mindvision/include/`保存编译所需的 MVSDK 头文件快照（`CameraApi.h`、`CameraDefine.h`、`CameraStatus.h`），`mindvision_wrapper.cpp`调用 `Camera*` 接口完成 USB 相机枚举、曝光/伽马设置、取流和资源释放，并用 `CameraImageProcess` 直接输出 BGR8 图像。

当前封装的实现约定：

- `init()` 枚举设备后按 `dev_num` 选择相机，关闭自动曝光，曝光默认 `3.0 ms`、伽马默认 `1.0`，触发模式为连续采集，并丢弃启动阶段的前 5 帧
- `read()` 按帧头尺寸分配缓冲，取流超时 `1000 ms`；连续失败超过 10 次后重新初始化，与 `hikcam` 的处理方式一致
- `getFps()` 读取 `CameraGetFrameRate()`，`setBrightness()` 映射到模拟增益 `CameraSetAnalogGain()`
- 曝光和伽马目前是构造函数默认值，还没有接入 `launch.cfg`

EnvCfg 离线包 `sources/mindvision_arm64_v2.1.0.37.tar.gz` 内的 arm64 `libMVSDK.so` SHA-256 为：

```text
23a4a84fb9bcedd515c32b89c4c9dac7fb98230a09b3c6c14da99927a4d462be
```

该动态库的 `DT_NEEDED` 只有 `librt`、`libpthread`、`libdl`、`libm`、`libc`，USB 访问由静态链接的 libusb 完成，因此目标设备不需要额外的 libusb 运行库。MVSDK 属于厂商 SDK，不在本仓库 MIT 许可范围内，再分发前应按迈德威视条款确认头文件和二进制文件的授权范围。

#### 可选后端：Hikvision MVS

`USE_HIKCAM=ON` 时改用 `sensor/hikcam/`。该目录保存 MVS 头文件快照，`hikcam_wrapper.cpp`调用 `MV_CC_*`接口完成 USB 相机枚举、采集、像素格式处理和资源释放。当前封装只枚举 USB 设备，不包含 GigE 相机枚举路径，CMake 通过 `MVS_PATH` 查找动态库。

EnvCfg 不再自动安装 MVS，该路径需要自行准备运行库并设置 `MVS_PATH`。`sources/MVS_aarch.deb` 仍然保留在 EnvCfg 仓库里，作为 `USE_HIKCAM=ON` 的离线备用包，需要时手动执行 `dpkg -i sources/MVS_aarch.deb` 并导出 `MVS_PATH=/opt/MVS/lib/aarch64/`。该包 SHA-256 为：

```text
b9e27ac9c0f7e649cf15be826e2bdfb1e70d5b9bab523adaac53fbb3206c98cb
```

Debian 元数据把版本写为 `2019-05-30`。包内 Release Note 指向 `MVS 2.1.0 build201228`，SDK 文档目录显示 `V3.1.0`，动态库名包含 `3.1.3.0`。`sensor/hikcam/` 中的头文件与该安装包内 `MVS/include/` 内容一致，仅换行格式不同。Hikrobot 的 [MVS Linux 安装说明](https://www.hikrobotics.com/en2/source/vision/video/2022/12/19/Standard%20Camera_How_to_Install_MVS%20in%20Linux_22.12.17.pdf)以 `MVS 2.1.0 build201228`为例。

### TinyMPC

`planner/tinympc/`直接编译为 `tinympcstatic`，`planner/Planner.cpp`使用它建立偏航和俯仰两个 MPC 求解器。当前 Planner 的预测时域为 `HORIZON = 100`，每个求解器限制为 10 次迭代。

这份源码可以确认来自 [TinyMPC 官方仓库](https://github.com/TinyMPC/TinyMPC)的 commit `7cecb25e450e888cbd431b446e1b14baf8c139d6`。上游仓库标注 MIT 许可。当前快照保留两处本地定制：注释掉收敛时输出，将 `Eigen.h` include 改为 `Eigen/Eigen`。后续上游加入的时间变化线性约束在本地快照中不存在。升级前应先重新审阅 Planner 的约束范围，并记录许可证归属和第三方声明。

## 模型与离线资产

代码按后端约定使用以下文件：

| 文件 | 后端 | 代码侧输入和输出约定 | 用途 |
| --- | --- | --- | --- |
| `asset/models/SKD250526.axmodel` | AXCL | 640 × 512，按 6720 个候选和每候选 21 个值解析 | AX650 主路径 |
| `asset/models/SKD250526.onnx` | TensorRT | 640 × 512，按 6720 个候选和每候选 21 个值解析 | TensorRT 路径 |
| `asset/models/SZU0526_fp32input_512x640_nopre_fixoutput.onnx` | MIGraphX | 640 × 512，代码按 20160 个候选和每候选 22 个值解析 | `ONNX` 后端路径 |
| `test.avi` | 视频输入 | 由 `sensor/video`读取 | 离线回放和示范 |

当前工作树的 SHA-256：

```text
ba89b91f7df6c36f4260fec8080bd6ff8596e3114c017df90e2fab57d3ebb154  asset/models/SKD250526.axmodel
0fdea1e9b894c2f2d24ae6a5e78b57cbe6acf20d62b8636fb66f68be63635426  asset/models/SKD250526.onnx
582dde276f67513e95ab87c5480e025bf102c508b541517609a48c37385d046e  asset/models/SZU0526_fp32input_512x640_nopre_fixoutput.onnx
7faf6d9a1a19e04af482748dfb49f66069043057f29b9cb424d2f5c623508742  test.avi
```

模型来源、训练数据、标签表和授权范围尚未形成完整记录。哈希只能确认文件内容，不代表模型或视频已经获得公开分发授权。

### 标签与装甲尺寸

当前代码侧的公共编号如下：

- `color_id`：`0` 表示红色，`1` 表示蓝色，`2` 表示灰色
- `tag_id`：`0` 表示无目标，`1` 到 `7` 表示机器人，`8` 表示前哨站，`9` 表示基地
- PnP 使用 `armor_number` 判断装甲尺寸。`0`、`1` 和 `8` 归为大装甲板，其余编号归为小装甲板

AXCL 和 TensorRT 保留模型输出的类别编号。MIGraphX 的 `SZU0526`路径会执行类别和颜色映射。训练标签与比赛目标编号的最终对应关系仍需结合模型标签表确认。

## 辅助工具

| 文件 | 输入或额外依赖 | 当前状态 |
| --- | --- | --- |
| `tools/handeye_calibration.py` | `handeye_calibration_data/`、棋盘格图像、`euler_*.txt`、OpenCV 和 NumPy | 示例脚本，内含固定相机参数 |
| `tools/pipeline_visualize.py` | 当前工作目录下的 `25.txt`、Matplotlib | 日志格式依赖外部文件，Stage View 标记为暂停使用 |
| `tools/data_plotter.py` | 已构建的 `./build/auto-aim`、Matplotlib Tk 后端 | 规划输出入口已移除，脚本暂不作为可用工具 |
| `tools/predictor_simulation.py` | OpenCV、NumPy、Matplotlib 和 Python `tinympc` 包 | Python 包与 C++ vendored TinyMPC 不是同一安装路径 |

这些脚本不参与 `auto-aim` 主程序构建。运行前需要准备脚本所需的输入文件和 Python 依赖。仓库不把现场日志和临时数据作为工具输入的一部分提交。

## 验证状态与待办

本次审计以静态检查为主。当前 Ubuntu/macOS 开发机没有 `/soc`、ROCm 或 TensorRT 运行库，也没有安装到系统路径的 RMCVSerial。独立下载的 RMCVSerial `V1.1.1` 源码已在临时目录完成 CMake 配置和构建。

相机后端的验证程度：`sensor/mindvision/mindvision_wrapper.cpp` 已用真实 OpenCV 和仓库内的 MVSDK 头文件编译成目标文件；`sensor_submodule.cpp` 在 `ENABLE_MINDVISION`、`ENABLE_HIKCAM` 和两种都关闭三种情况下都能通过语法检查；CMake 在 `MINDVISION_PATH`（`-D` 或环境变量）指向测试库时能完成配置，缺少 `libMVSDK.so` 时会给出明确报错；EnvCfg 的 MVSDK 安装步骤在仿真根目录里跑通了产物落盘和跳过分支。**没有在 AX650 实机上验证取流**，相机出图、曝光和帧率仍需要在目标设备上实测。

后续按以下顺序补齐：

- 记录 EnvCfg、RMCVSerial 和 TinyMPC 的精确版本或 commit
- 记录 MindVision MVSDK 的版本与再分发授权，并补齐模型和 `test.avi` 的来源与授权信息
- 在 AX650 实机上验证 MindVision 取流、曝光/伽马和帧率，并决定是否把曝光参数接入 `launch.cfg`
- 如继续维护 `sensor/hikcam`，统一 MVS 包的版本字段并确认授权范围
- 为 RMCVSerial 和 TinyMPC 形成第三方声明
- 为 EnvCfg 下载内容补充校验和，轮换并清理历史部署凭据
- 为辅助工具补充最小依赖说明，或明确标记为实验脚本
