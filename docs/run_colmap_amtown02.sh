#!/usr/bin/env bash
# COLMAP 稀疏重建：相机内参与畸变与 AMtown02_Mono.yaml（VO）一致。
# 分辨率：1224x1024；模型：FULL_OPENCV（含 k3；k4=k5=k6=0）
# 用法：在 colmap_ws 下执行  ./run_colmap_amtown02.sh

set -euo pipefail

if ! command -v colmap >/dev/null 2>&1; then
  echo "错误：未找到 colmap 命令（COLMAP 未安装或不在 PATH）。"
  echo "在 Ubuntu/WSL 上安装示例："
  echo "  sudo apt-get update && sudo apt-get install -y colmap"
  exit 1
fi

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

# 与 AMtown02_Mono.yaml 中 Camera1 / Camera.width / Camera.height 一致
CAM_MODEL="FULL_OPENCV"
# fx, fy, cx, cy, k1, k2, p1, p2, k3, k4, k5, k6
CAM_PARAMS="722.215,722.17,589.75,522.45,-0.0560,0.1180,0.00122,0.00064,-0.0627,0,0,0"

HEAD="env -u DISPLAY QT_QPA_PLATFORM=offscreen"

mkdir -p sparse

echo "== 1) feature_extractor（固定单相机参数，与 VO 统一）"
$HEAD colmap feature_extractor \
  --database_path database.db \
  --image_path images \
  --ImageReader.camera_model "$CAM_MODEL" \
  --ImageReader.single_camera 1 \
  --ImageReader.camera_params "$CAM_PARAMS" \
  --SiftExtraction.use_gpu 0

echo "== 2) sequential_matcher（序列/VO 相邻帧）"
$HEAD colmap sequential_matcher \
  --database_path database.db \
  --SequentialMatching.overlap 30 \
  --SequentialMatching.quadratic_overlap 1 \
  --SiftMatching.use_gpu 0

echo "== 3) mapper（不在 BA 中优化内参与畸变，保持与 YAML 一致）"
$HEAD colmap mapper \
  --database_path database.db \
  --image_path images \
  --output_path sparse \
  --Mapper.ba_refine_focal_length 0 \
  --Mapper.ba_refine_principal_point 0 \
  --Mapper.ba_refine_extra_params 0 \
  --Mapper.num_threads 4 \
  --Mapper.ba_global_images_freq 1000 \
  --Mapper.ba_global_points_freq 500000 \
  --Mapper.abs_pose_max_error 20 \
  --Mapper.abs_pose_min_inlier_ratio 0.15 \
  --Mapper.max_reg_trials 6

echo "== 4) 检查稀疏模型（主模型多为 sparse/0）"
colmap model_analyzer --path sparse/0

echo "完成。OpenSplat 若报相机模型不兼容，再对该目录做 image_undistorter 转 PINHOLE（见 opensplatting README）。"
