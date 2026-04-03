#!/usr/bin/env bash
# COLMAP image_undistorter：在已有 sparse 上生成去畸变图 + PINHOLE 相机（供 OpenSplat 等不支持 FULL_OPENCV 的工具使用）。
# 依赖：colmap 已安装；输入为「原图目录」+「稀疏模型目录」。
#
# 用法：
#   chmod +x colmap_undistort_to_pinhole.sh
#   ./colmap_undistort_to_pinhole.sh
#
# 可选环境变量（覆盖默认）：
#   BASE=/home/ccxx/colmap_ws
#   IMAGE_SUB=images
#   SPARSE_SUB=sparse/0
#   DENSE_SUB=dense
#   PACK=1   # 是否额外生成 opensplat_input（images + sparse/0）

set -euo pipefail

BASE="${BASE:-/home/ccxx/colmap_ws}"
IMAGE_SUB="${IMAGE_SUB:-images}"
SPARSE_SUB="${SPARSE_SUB:-sparse/0}"
DENSE_SUB="${DENSE_SUB:-dense}"
PACK="${PACK:-1}"

IMAGES="${BASE}/${IMAGE_SUB}"
SPARSE_IN="${BASE}/${SPARSE_SUB}"
DENSE_OUT="${BASE}/${DENSE_SUB}"

if [[ ! -d "$IMAGES" ]]; then
  echo "错误：图像目录不存在: $IMAGES" >&2
  exit 1
fi
if [[ ! -f "${SPARSE_IN}/cameras.bin" ]]; then
  echo "错误：稀疏模型不存在: ${SPARSE_IN}/cameras.bin" >&2
  exit 1
fi
if ! command -v colmap >/dev/null 2>&1; then
  echo "错误：未找到 colmap" >&2
  exit 1
fi

echo "工程根目录: $BASE"
echo "原图目录:   $IMAGES"
echo "稀疏输入:   $SPARSE_IN"
echo "输出目录:   $DENSE_OUT  （将重建）"
echo ""

rm -rf "$DENSE_OUT"
mkdir -p "$DENSE_OUT"

# WSL / 无头环境：避免 Qt 连接无效 DISPLAY
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap image_undistorter \
  --image_path "$IMAGES" \
  --input_path "$SPARSE_IN" \
  --output_path "$DENSE_OUT" \
  --output_type COLMAP

echo ""
echo "完成。典型输出结构："
echo "  ${DENSE_OUT}/images/   <- 去畸变后的图像"
echo "  ${DENSE_OUT}/sparse/   <- 与上面对应的模型（一般为 PINHOLE）"
echo ""

if [[ "${PACK}" == "1" ]]; then
  PACK_DIR="${BASE}/opensplat_input"
  echo "生成 OpenSplat 常见目录结构: $PACK_DIR"
  rm -rf "$PACK_DIR"
  mkdir -p "$PACK_DIR/images"
  mkdir -p "$PACK_DIR/sparse/0"
  shopt -s nullglob
  imgs=( "${DENSE_OUT}/images/"* )
  if ((${#imgs[@]})); then cp -a "${imgs[@]}" "$PACK_DIR/images/"; fi
  bins=( "${DENSE_OUT}/sparse/"*.bin )
  if ((${#bins[@]})); then cp -a "${bins[@]}" "$PACK_DIR/sparse/0/"; fi
  shopt -u nullglob
  [[ -f "${DENSE_OUT}/sparse/project.ini" ]] && cp -a "${DENSE_OUT}/sparse/project.ini" "$PACK_DIR/sparse/0/" || true
  echo "已复制到: $PACK_DIR （上传时可只打该目录）"
  du -sh "$DENSE_OUT" "$PACK_DIR" 2>/dev/null || true
else
  du -sh "$DENSE_OUT" 2>/dev/null || true
fi

echo ""
echo "验证相机模型（应为 PINHOLE）："
TMP_TXT="$(mktemp -d)"
if colmap model_converter \
  --input_path "${DENSE_OUT}/sparse" \
  --output_path "$TMP_TXT" \
  --output_type TXT 2>/dev/null; then
  head -6 "${TMP_TXT}/cameras.txt" || true
fi
rm -rf "$TMP_TXT"
