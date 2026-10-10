#!/usr/bin/env bash
#
# 在 AX650 离线调试容器里执行命令。
#
#   bash scripts/ax650-image/run.sh                                # 交互式 shell
#   bash scripts/ax650-image/run.sh -c 'cmake --build build -j4'   # 跑一条命令
#   bash scripts/ax650-image/run.sh uname -m
#   REPO=/path/to/repo bash scripts/ax650-image/run.sh
#
# 环境变量：
#   TAG              镜像标签，默认 V3.6.2
#   REPO             要挂进容器的仓库，默认本仓库根目录
#   AX650_AS_ROOT=1  Linux 上不降权，仍用 root（默认会切成你的 uid，避免 build/ 变 root 属主）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${TAG:-V3.6.2}"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
IMAGE="ax650-env:${TAG}"

die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

have docker || die "需要 docker"
docker info >/dev/null 2>&1 || die "连不上 docker daemon"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "没有镜像 $IMAGE
     先构建：  bash $HERE/build.sh --axp /path/to/fw.axp
     或搬过来：bash $HERE/import.sh ax650-images-${TAG}.tar.zst"

[ -d "$REPO" ] || die "REPO 不是目录: $REPO"

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

# x86_64 宿主跑 arm64 容器需要 QEMU
if [ "$HOST_ARCH" != "arm64" ] && [ "$HOST_ARCH" != "aarch64" ]; then
    if ! docker run --rm --platform linux/arm64 --entrypoint /bin/true "$IMAGE" >/dev/null 2>&1; then
        die "当前是 ${HOST_ARCH}，跑 linux/arm64 容器需要 QEMU 用户态模拟：
       sudo apt install qemu-user-static binfmt-support
       sudo systemctl restart systemd-binfmt     # 或者直接重启
     装完验证：docker run --rm --platform linux/arm64 $IMAGE uname -m  → 应该输出 aarch64"
    fi
    warn "$HOST_ARCH 宿主，容器靠 QEMU 模拟运行，编译会明显变慢"
fi

# 想跑别的命令时补上 bash，否则会被当成镜像 CMD 的替换
if [ $# -eq 0 ]; then
    set -- /bin/bash
elif [ "${1#-}" != "$1" ]; then
    set -- /bin/bash "$@"
fi

# Linux 上默认降权到当前用户，否则 build/ 和 log/ 会变 root 属主，后面删都删不掉
USER_ARGS=()
if [ "$HOST_OS" = Linux ] && [ "${AX650_AS_ROOT:-0}" != "1" ]; then
    USER_ARGS=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi

# 只在真正有终端时分配 TTY，这样也能在脚本/CI 里调
TTY_ARGS=()
if [ -t 0 ] && [ -t 1 ]; then
    TTY_ARGS=(-t)
fi

exec docker run --rm -i ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
    --platform linux/arm64 \
    -v "$REPO:/work" \
    -w /work \
    ${USER_ARGS[@]+"${USER_ARGS[@]}"} \
    -e LANG=C.UTF-8 \
    -e LD_LIBRARY_PATH=/soc/lib:/usr/local/lib \
    -e MINDVISION_PATH=/usr/lib/aarch64-linux-gnu \
    -e MVS_PATH=/opt/MVS/lib/aarch64 \
    "$IMAGE" "$@"
