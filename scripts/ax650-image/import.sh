#!/usr/bin/env bash
#
# 在目标机器（比如 Ubuntu）上还原 export.sh 打出来的镜像包。
#
#   bash scripts/ax650-image/import.sh ax650-images-V3.6.2.tar.zst
#   bash scripts/ax650-image/import.sh ~/下载/ax650-images-V3.6.2.tar.gz
#
# 支持 .tar / .tar.gz / .tar.zst / .tar.xz，按扩展名自动识别。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${TAG:-V3.6.2}"
IN="${1:-}"

die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -n "$IN" ] || die "用法: bash $HERE/import.sh <镜像包路径>"
[ -f "$IN" ] || die "找不到文件: $IN"
command -v docker >/dev/null 2>&1 || die "需要 docker"
docker info >/dev/null 2>&1 || die "连不上 docker daemon"

# 校验（如果旁边有 .sha256）
if [ -f "$IN.sha256" ]; then
    echo "==> 校验 sha256"
    if have sha256sum; then
        sha256sum -c "$IN.sha256"
    elif have shasum; then
        shasum -a 256 -c "$IN.sha256"
    fi
fi

echo "==> 解包 $IN"
case "$IN" in
    *.tar.zst)  have zstd || die "需要 zstd：sudo apt install zstd"; zstd -dc -- "$IN" | docker load ;;
    *.tar.gz|*.tgz) gzip -dc -- "$IN" | docker load ;;
    *.tar.xz)   have xz   || die "需要 xz"; xz -dc -- "$IN" | docker load ;;
    *.tar)      docker load -i "$IN" ;;
    *)          echo "    扩展名不认识，按未压缩 tar 处理" >&2; docker load -i "$IN" ;;
esac

echo
echo "==> 本地镜像"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep '^ax650-' || true

if ! docker image inspect "ax650-env:$TAG" >/dev/null 2>&1; then
    echo
    echo "[warn] 没看到 ax650-env:${TAG}。如果包里的 tag 不是 ${TAG}，用 TAG=xxx 重跑本脚本，"
    echo "       或者直接 docker images 看实际 tag。"
fi

cat <<EOF

进容器：
  bash $HERE/run.sh
EOF
