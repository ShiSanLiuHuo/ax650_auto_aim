#!/usr/bin/env bash
#
# 把 AX650 镜像打包成一个文件，方便搬到别的机器（比如 Ubuntu 服务器）离线还原。
#
#   bash scripts/ax650-image/export.sh                     # 默认输出到当前目录
#   OUT=/data/ax650.tar.zst bash scripts/ax650-image/export.sh
#   TAG=V3.6.2 bash scripts/ax650-image/export.sh
#
# docker save 一次给多个镜像时会自动去重共享层，所以 ax650-rootfs 那 8 GB
# 只会出现一次，不用分别打包。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${TAG:-V3.6.2}"
OUT="${OUT:-$PWD/ax650-images-$TAG.tar}"

die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

command -v docker >/dev/null 2>&1 || die "需要 docker"

# 收集存在的镜像（rootfs 可能被删了，那就只打包 env）
IMAGES=()
for img in "ax650-env:$TAG" "ax650-rootfs:$TAG"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        IMAGES+=("$img")
    fi
done
[ "${#IMAGES[@]}" -gt 0 ] || die "本地没有 ax650-env:$TAG 或 ax650-rootfs:$TAG"

# 挑一个压缩器
COMP=()
EXT=""
if have zstd; then
    COMP=(zstd -T0 -3 -q); EXT=".zst"
elif have pigz; then
    COMP=(pigz -p "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"); EXT=".gz"
elif have gzip; then
    COMP=(gzip); EXT=".gz"
else
    echo "[warn] 没找到 zstd/pigz/gzip，不压缩，文件会很大" >&2
fi
[ -n "$EXT" ] && case "$OUT" in *"$EXT") ;; *) OUT="$OUT$EXT" ;; esac

echo "==> 打包 ${IMAGES[*]}"
echo "    输出: $OUT"

# 空间检查
NEED_GB=$(docker image inspect "${IMAGES[@]}" --format '{{.Size}}' \
    | awk '{s+=$1} END {printf "%.1f", s/1000/1000/1000}')
echo "    要打进去的内容约 ${NEED_GB} GB（这是 docker save 出来的 tar 大小，压缩后通常只剩一半左右）"
FREE_GB=$(df -Pk "$(dirname "$OUT")" | awk 'NR==2 {printf "%.1f", $4/1024/1024}')
echo "    目标分区剩余 ${FREE_GB} GB"

tmp="$OUT.part"
docker save "${IMAGES[@]}" | "${COMP[@]}" > "$tmp"
mv "$tmp" "$OUT"

echo
ls -lh "$OUT"
if have sha256sum; then
    sha256sum "$OUT" | tee "$OUT.sha256"
elif have shasum; then
    shasum -a 256 "$OUT" | tee "$OUT.sha256"
fi

cat <<EOF

拿到目标机器上还原：
  bash scripts/ax650-image/import.sh $(basename "$OUT")
EOF
