# AX650 离线调试环境：在 ax650-rootfs 基础镜像上补齐编译依赖和厂商 SDK。
#
# 一般不用直接 docker build，交给 build.sh（它会把 sources/ 准备好再调 docker build）：
#     bash scripts/ax650-image/build.sh --axp /path/to/fw.axp --stage env
#
# 手动构建的话，构建上下文是一个含 sources/ 的目录（通常就是 work/env/）：
#     docker build --platform linux/arm64 -f scripts/ax650-image/env/Dockerfile \
#         -t ax650-env:V3.6.2 scripts/ax650-image/work/env
#
# sources/ 里需要：
#   axcl_inc.tar                       来自 EnvCfg，AXCL 头文件
#   mindvision_arm64_v2.1.0.37.tar.gz  来自 EnvCfg，迈德威视 MVSDK
#   MVS_aarch.deb                      来自 EnvCfg，海康 MVS（可选后端）
#   rmcv_serial-V1.1.1.tar             gitlab.rmshtech.com 的 V1.1.1 归档

FROM ax650-rootfs:V3.6.2

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LD_LIBRARY_PATH=/soc/lib:/usr/local/lib

# ------------------------------------------------ 容器化修补（apt 之前必须做）
# 真机上 /tmp 和 /run/lock 是 tmpfs(mode=1777)，导出的 rootfs 里只是普通目录 0755，
# apt 下载时降权到 _apt 用户就写不进临时文件，报
# "Couldn't create temporary file /tmp/apt.conf.XXX for passing config to apt-key"。
# 顺便删掉容器里没用的 docker.com / mozilla PPA，免得拖慢 apt。
RUN set -eux; \
    chmod 1777 /tmp /var/tmp; \
    mkdir -p /run/lock; \
    chmod 1777 /run/lock; \
    rm -f /etc/apt/sources.list.d/docker.list \
          /etc/apt/sources.list.d/mozillateam-ubuntu-ppa-jammy.list

# ---------------------------------------------------------------- 通用编译依赖
# 对应 EnvCfg AutoInstall.sh 第 2 行，另外补上 pkg-config / ccache / wget。
RUN set -eux; \
    if ! apt-get update; then \
        echo ">>> aliyun 源不可用，切换到清华 TUNA"; \
        sed -i 's|mirrors\.aliyun\.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list; \
        apt-get update; \
    fi; \
    apt-get install -y --no-install-recommends \
        gcc g++ cmake make ninja-build pkg-config ccache \
        libboost-dev libopencv-dev libeigen3-dev libusb-1.0-0 \
        ca-certificates curl wget git xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    gcc --version | head -1; \
    cmake --version | head -1; \
    pkg-config --modversion opencv4

# ------------------------------------------------------- AXCL 头文件 -> /soc/include
COPY sources/axcl_inc.tar /tmp/
RUN set -eux; \
    tar -xf /tmp/axcl_inc.tar -C /soc; \
    rm -f /tmp/axcl_inc.tar; \
    test -f /soc/include/ax_ivps_api.h; \
    ls /soc/include | wc -l

# ------------------------------------------------------------------ MindVision MVSDK
COPY sources/mindvision_arm64_v2.1.0.37.tar.gz /tmp/
RUN set -eux; \
    mkdir -p /tmp/mv; \
    tar -xzf /tmp/mindvision_arm64_v2.1.0.37.tar.gz -C /tmp/mv; \
    install -d /usr/include/mindvision; \
    cp /tmp/mv/mindvision/include/*.h /usr/include/mindvision/; \
    cp /tmp/mv/mindvision/lib/arm64/libMVSDK.so /usr/lib/aarch64-linux-gnu/; \
    cp /tmp/mv/mindvision/*-mvusb.rules /etc/udev/rules.d/; \
    getent group mvusb_dev >/dev/null || groupadd -r mvusb_dev; \
    ldconfig; \
    rm -rf /tmp/mv /tmp/mindvision_arm64_v2.1.0.37.tar.gz; \
    test -f /usr/lib/aarch64-linux-gnu/libMVSDK.so

ENV MINDVISION_PATH=/usr/lib/aarch64-linux-gnu

# ------------------------------------------------- 海康 MVS（可选后端 USE_HIKCAM）
# 不跑 deb 的 postinst：它要 insmod 驱动、装 logserver 服务，在容器里既无意义也会报错。
# 这里只做确定性的文件落盘，等价于 setup.sh 里真正的 SDK 展开步骤。
#
# 两个坑：
#   1. MVS.tar.gz 内部的路径自带 MVS/ 前缀，必须解到 /opt 而不是 /opt/MVS；
#   2. 官方包只提供 libMvCameraControl.so.3.1.3.0，没有 .so 软链，而
#      sensor/CMakeLists.txt 找的是 libMvCameraControl.so，所以要自己补软链。
COPY sources/MVS_aarch.deb /tmp/
RUN set -eux; \
    mkdir -p /tmp/mvs; \
    dpkg-deb -x /tmp/MVS_aarch.deb /tmp/mvs; \
    tar -C /opt -xzf /tmp/mvs/opt/MVS_Install_Temp/MVS.tar.gz; \
    tar -C /opt/MVS/bin -xzf /opt/MVS/bin/libcommon.tar.gz; \
    cp -rf /opt/MVS/bin/libcommon/* /opt/MVS/bin/; \
    rm -rf /opt/MVS/bin/libcommon; \
    cd /opt/MVS/lib/aarch64; \
    for f in *.so.*; do ln -sf "$f" "${f%%.so.*}.so"; done; \
    printf '%s\n' /opt/MVS/lib/aarch64 /soc/lib /usr/local/lib > /etc/ld.so.conf.d/ax650.conf; \
    ldconfig; \
    rm -rf /tmp/mvs /tmp/MVS_aarch.deb; \
    ls -l /opt/MVS/lib/aarch64/libMvCameraControl.so

ENV MVS_PATH=/opt/MVS/lib/aarch64
ENV MVCAM_COMMON_RUNENV=/opt/MVS/lib

# ------------------------------------------------------------------- RMCVSerial V1.1.1
COPY sources/rmcv_serial-V1.1.1.tar /tmp/
RUN set -eux; \
    mkdir -p /tmp/rmcv; \
    tar -xf /tmp/rmcv_serial-V1.1.1.tar -C /tmp/rmcv; \
    cmake -S /tmp/rmcv/rmcv_serial-V1.1.1 -B /tmp/rmcv/build -DCMAKE_BUILD_TYPE=Release; \
    cmake --build /tmp/rmcv/build -j"$(nproc)"; \
    cmake --install /tmp/rmcv/build; \
    ldconfig; \
    rm -rf /tmp/rmcv /tmp/rmcv_serial-V1.1.1.tar; \
    ldconfig -p | grep RMCVSerial

WORKDIR /work
CMD ["/bin/bash"]
