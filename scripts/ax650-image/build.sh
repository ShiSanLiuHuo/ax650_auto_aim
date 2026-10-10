#!/usr/bin/env bash
#
# AX650 固件包 (.axp) -> 可离线运行的 Docker 镜像
#
# 支持两种宿主：
#   macOS  —— 用特权容器做 loop mount（Docker Desktop 的 LinuxKit 内核支持 mount -o loop）
#   Ubuntu —— 有 root 就直接原生 loop mount（更快），没有就退回特权容器
#
# .axp 其实是个 ZIP，里面装的是 Android sparse 格式的 ext4 分区镜像。
# sparse 不能直接 loop mount，所以先流式转成 raw（洞用 lseek 写出，不真占盘），
# 再把 /opt /soc /param 三个独立分区并回根文件系统，tar 出来 docker import。
#
# 用法：
#   bash scripts/ax650-image/build.sh --axp /path/to/fw.axp
#   AXP=/path/to/fw.axp bash scripts/ax650-image/build.sh
#
# 常用参数：
#   --axp PATH        固件包（也可用环境变量 AXP）
#   --envcfg PATH     EnvCfg 仓库，用来取 axcl_inc.tar / MVSDK / MVS（环境变量 ENVCFG）
#   --tag TAG         镜像标签后缀，默认 V3.6.2
#   --work DIR        中间文件目录，默认 <脚本目录>/work
#   --stage STAGE     raw | tar | import | env（默认 env，即全流程）
#   --backend B        auto | native | docker
#   --tool-image IMG  用特权容器时指定镜像（默认自动挑一个本地已有的）
#   --jobs N          编译并发
#   --rmcserial PATH  本地已有的 RMCVSerial tar（不联网时用）
#   --force           重做已有产物
#   -h, --help
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------- 默认值
AXP="${AXP:-}"
ENVCFG="${ENVCFG:-}"
TAG="${TAG:-V3.6.2}"
WORK="${WORK:-$HERE/work}"
STAGE="${STAGE:-env}"
BACKEND="${BACKEND:-auto}"
TOOL_IMAGE="${TOOL_IMAGE:-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)}"
RMCSERIAL_TAR="${RMCSERIAL_TAR:-}"
FORCE=0

ROOTFS_IMAGE="ax650-rootfs:$TAG"
ENV_IMAGE="ax650-env:$TAG"
RMCSERIAL_URL="https://gitlab.rmshtech.com/computer-vision/tools/rmcv_serial/-/archive/V1.1.1/rmcv_serial-V1.1.1.tar"

# ----------------------------------------------------------------- 输出
if [ -t 1 ]; then
    C_R='\033[1;36m'; C_Y='\033[1;33m'; C_E='\033[1;31m'; C_0='\033[0m'
else
    C_R=''; C_Y=''; C_E=''; C_0=''
fi
say()  { printf '\n%s==> %s%s\n' "$C_R" "$*" "$C_0"; }
warn() { printf '%s[warn] %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die()  { printf '%s[error] %s%s\n' "$C_E" "$*" "$C_0" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# ----------------------------------------------------------------- 参数
while [ $# -gt 0 ]; do
    case "$1" in
        --axp)        AXP="$2"; shift 2 ;;
        --envcfg)     ENVCFG="$2"; shift 2 ;;
        --tag)        TAG="$2"; ROOTFS_IMAGE="ax650-rootfs:$TAG"; ENV_IMAGE="ax650-env:$TAG"; shift 2 ;;
        --work)       WORK="$2"; shift 2 ;;
        --stage)      STAGE="$2"; shift 2 ;;
        --backend)    BACKEND="$2"; shift 2 ;;
        --tool-image) TOOL_IMAGE="$2"; shift 2 ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        --rmcserial)  RMCSERIAL_TAR="$2"; shift 2 ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage ;;
        *)            die "未知参数: $1（--help 看用法）" ;;
    esac
done

case "$STAGE"   in raw|tar|import|env)          ;; *) die "--stage 只能是 raw | tar | import | env" ;; esac
case "$BACKEND" in auto|native|docker)          ;; *) die "--backend 只能是 auto | native | docker" ;; esac

# ----------------------------------------------------------------- 平台探测
case "$(uname -s)" in
    Darwin) HOST_OS=macos ;;
    Linux)  HOST_OS=linux ;;
    *)      die "只支持 macOS 和 Linux，当前是 $(uname -s)" ;;
esac
HOST_ARCH="$(uname -m)"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

mkdir -p "$WORK"

# ----------------------------------------------------------------- 环境检查
check_env() {
    have python3 || die "需要 python3"
    have docker  || die "需要 docker"
    docker info >/dev/null 2>&1 || die "连不上 docker daemon。macOS 上先 open -a Docker；Linux 上确认服务已起、当前用户在 docker 组里"

    SERVER_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo '?')"
    if [ "$SERVER_ARCH" != "arm64" ] && [ "$SERVER_ARCH" != "aarch64" ]; then
        warn "docker daemon 是 ${SERVER_ARCH}，而镜像是 linux/arm64。"
        warn "构建没问题，但在 x86_64 上跑这个容器需要 QEMU："
        warn "  sudo apt install qemu-user-static binfmt-support"
    fi

    if [ "$STAGE" != raw ]; then
        [ -n "$AXP" ] || die "没给固件包。用 --axp /path/to/xxx.axp 或环境变量 AXP"
        [ -f "$AXP" ] || die "找不到固件包: $AXP"
    fi
}

# 找一个本地已有的、带 mount/losetup/tar 的镜像当特权工具容器
pick_tool_image() {
    [ -n "$TOOL_IMAGE" ] && return
    for cand in docker-napcat-qce:latest ubuntu:24.04 ubuntu:22.04 debian:12 debian:stable-slim; do
        if docker image inspect "$cand" >/dev/null 2>&1; then TOOL_IMAGE="$cand"; return; fi
    done
    die "需要特权工具容器（要带 mount / losetup / tar），但本地没找到合适的镜像。
     办法一：--backend native（Linux 上用 root 原生 mount，不需要容器）
     办法二：--tool-image ubuntu:22.04（会先 docker pull）"
}

# 选解包后端
pick_backend() {
    [ "$BACKEND" != auto ] && return
    if [ "$HOST_OS" = linux ]; then BACKEND=native; else BACKEND=docker; fi
}

# ----------------------------------------------------------------- 1. sparse -> raw
PARTITIONS="rootfs:ubuntu_rootfs_desktop_sparse.ext4 opt:opt_sparse.ext4 soc:soc_sparse.ext4 param:param_sparse.ext4"

stage_raw() {
    say "列出 .axp 内的分区"
    python3 "$HERE/sparse2raw.py" --list "$AXP"

    say "Android sparse -> raw"
    for p in $PARTITIONS; do
        name="${p%%:*}"; member="${p#*:}"
        if [ -f "$WORK/$name.raw" ] && [ "$FORCE" -eq 0 ]; then
            printf '    %-10s 已存在，跳过（--force 可重做）\n' "$name.raw"
            continue
        fi
        rm -f "$WORK/$name.raw"
        python3 "$HERE/sparse2raw.py" "$AXP" "$member" "$WORK/$name.raw"
    done
    for name in rootfs opt soc param; do
        [ -f "$WORK/$name.raw" ] || die "缺少 $WORK/$name.raw"
    done
}

# ----------------------------------------------------------------- 2. 合并分区 + 导出 tar
stage_tar_native() {
    local mnt="$WORK/mnt"
    $SUDO rm -rf "$mnt"
    $SUDO mkdir -p "$mnt/rootfs" "$mnt/opt" "$mnt/soc" "$mnt/param"

    # shellcheck disable=SC2317
    cleanup_mnt() {
        for d in param soc opt rootfs; do $SUDO umount "$mnt/$d" 2>/dev/null || true; done
    }
    trap cleanup_mnt EXIT

    $SUDO mount -o loop    "$WORK/rootfs.raw" "$mnt/rootfs"
    $SUDO mount -o loop,ro "$WORK/opt.raw"    "$mnt/opt"
    $SUDO mount -o loop,ro "$WORK/soc.raw"    "$mnt/soc"
    $SUDO mount -o loop,ro "$WORK/param.raw"  "$mnt/param"

    for d in opt soc param; do
        $SUDO tar -C "$mnt/$d" --exclude=./lost+found -cf - . | $SUDO tar -C "$mnt/rootfs/$d" -xf -
    done
    # 清掉日志和临时文件，别把镜像撑大
    $SUDO rm -rf "$mnt/rootfs/var/log/"* "$mnt/rootfs/tmp/"* "$mnt/rootfs/root/.cache"

    say "导出 tar"
    $SUDO tar -C "$mnt/rootfs" --numeric-owner -cf "$WORK/ax650-rootfs.tar" .

    cleanup_mnt
    trap - EXIT
    $SUDO rm -rf "$mnt"
    $SUDO chown "$(id -u):$(id -g)" "$WORK/ax650-rootfs.tar"   # 交还属主，免得后面删不掉
}

stage_tar_docker() {
    pick_tool_image
    say "在特权容器里 loop mount 并导出 tar（工具镜像: ${TOOL_IMAGE}）"
    docker run --rm --privileged --entrypoint /bin/sh -v "$WORK:/work" "$TOOL_IMAGE" -c '
set -e
mkdir -p /mnt/rootfs /mnt/opt /mnt/soc /mnt/param
mount -o loop      /work/rootfs.raw /mnt/rootfs
mount -o loop,ro   /work/opt.raw    /mnt/opt
mount -o loop,ro   /work/soc.raw    /mnt/soc
mount -o loop,ro   /work/param.raw  /mnt/param
for d in opt soc param; do
    mkdir -p /mnt/rootfs/$d
    tar -C /mnt/$d --exclude=./lost+found -cf - . | tar -C /mnt/rootfs/$d -xf -
done
rm -rf /mnt/rootfs/var/log/* /mnt/rootfs/tmp/* /mnt/rootfs/root/.cache
tar -C /mnt/rootfs --numeric-owner -cf /work/ax650-rootfs.tar .
umount /mnt/param /mnt/soc /mnt/opt /mnt/rootfs
echo TAR_OK
'
}

stage_tar() {
    if [ -f "$WORK/ax650-rootfs.tar" ] && [ "$FORCE" -eq 0 ]; then
        printf '    ax650-rootfs.tar 已存在，跳过（--force 可重做）\n'
        return
    fi
    pick_backend
    say "合并 /opt /soc /param 到根文件系统（后端: ${BACKEND}）"
    if [ "$BACKEND" = native ]; then
        [ "$HOST_OS" = linux ] || die "native 后端只在 Linux 上可用"
        [ -n "$SUDO" ] && ! $SUDO -n true 2>/dev/null && warn "原生 mount 需要 sudo，可能会提示输密码"
        stage_tar_native
    else
        stage_tar_docker
    fi
    ls -lh "$WORK/ax650-rootfs.tar"
}

# ----------------------------------------------------------------- 3. docker import
stage_import() {
    say "docker import -> $ROOTFS_IMAGE"
    docker import --platform linux/arm64 \
        --change 'ENV LANG=C.UTF-8' \
        --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        --change 'ENV LD_LIBRARY_PATH=/soc/lib:/usr/local/lib' \
        --change 'WORKDIR /root' \
        "$WORK/ax650-rootfs.tar" "$ROOTFS_IMAGE"
    docker run --rm "$ROOTFS_IMAGE" bash -c 'echo "    验证: $(uname -m) $(. /etc/os-release; echo "$PRETTY_NAME")"'
}

# ----------------------------------------------------------------- 4. 构建 ax650-env
find_envcfg() {
    if [ -n "$ENVCFG" ]; then
        [ -d "$ENVCFG" ] || die "找不到 EnvCfg 目录: $ENVCFG"
        return
    fi
    for cand in \
        "$HOME/PHOENIX_auto_aim_AX650-EnvCfg" \
        "$HOME/SHtech_auto_aim_AX650-EnvCfg" \
        "$HOME/ax650/PHOENIX_auto_aim_AX650-EnvCfg" \
        "$(dirname "$HERE")/../../SHtech_auto_aim_AX650-EnvCfg"
    do
        [ -d "$cand/sources" ] && { ENVCFG="$(cd "$cand" && pwd)"; return; }
    done
    die "没找到 EnvCfg 来源。用 --envcfg /path/to/PHOENIX_auto_aim_AX650-EnvCfg
     需要其中的 sources/{axcl_inc.tar, mindvision_arm64_*.tar.gz, MVS_aarch.deb}"
}

stage_env() {
    find_envcfg
    say "准备 docker build 上下文（$WORK/env）"
    mkdir -p "$WORK/env/sources"
    for f in axcl_inc.tar MVS_aarch.deb; do
        [ -f "$WORK/env/sources/$f" ] || cp "$ENVCFG/sources/$f" "$WORK/env/sources/"
    done
    compgen -G "$WORK/env/sources/mindvision_arm64_*.tar.gz" >/dev/null \
        || cp "$ENVCFG"/sources/mindvision_arm64_*.tar.gz "$WORK/env/sources/"
    if [ ! -f "$WORK/env/sources/rmcv_serial-V1.1.1.tar" ]; then
        if [ -n "$RMCSERIAL_TAR" ]; then
            cp "$RMCSERIAL_TAR" "$WORK/env/sources/rmcv_serial-V1.1.1.tar"
        else
            say "下载 RMCVSerial V1.1.1"
            curl -fsSL -o "$WORK/env/sources/rmcv_serial-V1.1.1.tar" "$RMCSERIAL_URL" \
                || die "下载失败。可本地下好再用 --rmcserial /path/to/rmcv_serial-V1.1.1.tar"
        fi
    fi
    ls -la "$WORK/env/sources"

    say "docker build -> $ENV_IMAGE"
    docker build --platform linux/arm64 -f "$HERE/env/Dockerfile" -t "$ENV_IMAGE" "$WORK/env"
}

# ----------------------------------------------------------------- main
check_env
case "$STAGE" in
    raw)    stage_raw ;;
    tar)    stage_raw; stage_tar ;;
    import) stage_raw; stage_tar; stage_import ;;
    env)    stage_raw; stage_tar; stage_import; stage_env ;;
esac

say "完成"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep '^ax650-' || true
cat <<EOF

进容器：
  bash $HERE/run.sh

搬到别的机器离线用：
  bash $HERE/export.sh            # 打成一个文件
  bash $HERE/import.sh <文件>     # 在目标机还原
EOF
