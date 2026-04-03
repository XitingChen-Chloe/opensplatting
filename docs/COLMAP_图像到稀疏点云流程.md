# 从图像到稀疏 3D 点云（OpenSplat 之前）

本文说明在 **OpenSplat** 训练之前，如何用 **COLMAP** 从 RGB 图像得到 **稀疏重建**（相机位姿 + 3D 点），工程目录以 `colmap_ws` 为例。

**OpenSplat 所需**：`images/`（原图）+ `sparse/<模型ID>/`（至少含 `cameras.bin`、`images.bin`、`points3D.bin`，且含稀疏点）。稠密 MVS **不是** OpenSplat 的硬性前置。

---

## 1. 环境与目录

- **COLMAP**：`colmap --version`（示例：3.7）
- **工作目录示例**：

```text
colmap_ws/
├── images/           # RGB 图像（文件名、顺序与后续数据库一致）
├── database.db       # SQLite：特征、匹配、图像元数据
└── sparse/           # 稀疏重建输出（mapper 生成）
    └── 0/            # 或其它编号（多模型时可有 0,1,2…）
```

首次使用前若还没有 `database.db`，需先做 **特征提取**；若已从别处拷贝 `database.db`，可跳过提取，直接进入匹配或重建（视该库是否已含匹配而定）。

---

## 2. 特征提取（若无 `database.db` 或未提特征）

在工程根目录执行：

```bash
cd /path/to/colmap_ws

# 无图形界面时（WSL 常见）
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap feature_extractor \
  --database_path database.db \
  --image_path images
```

若 COLMAP 为 **CPU 版**（`colmap -h` 显示 `without CUDA`），可加：

```bash
  --SiftExtraction.use_gpu 0
```

（参数名以 `colmap feature_extractor -h` 为准。）

---

## 3. 特征匹配

按数据类型选择：

| 类型 | 命令 |
|------|------|
| **视频/VO 序列**（相邻帧相关） | `sequential_matcher` |
| **无序/环绕** | `exhaustive_matcher` 或 `vocab_tree_matcher` |

**顺序匹配示例**（与下文 WSL 无头环境一致）：

```bash
cd /path/to/colmap_ws

env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap sequential_matcher \
  --database_path database.db \
  --SequentialMatching.overlap 30 \
  --SequentialMatching.quadratic_overlap 1 \
  --SiftMatching.use_gpu 0
```

说明：

- **`env -u DISPLAY`**：避免 Cursor/远程给 WSL 设置了无效 `DISPLAY` 时 Qt 报错。
- **`QT_QPA_PLATFORM=offscreen`**：无窗口运行。
- **`--SiftMatching.use_gpu 0`**：CPU 版 COLMAP 或无 OpenGL 环境时避免 SiftGPU/OpenGL 崩溃。

匹配结果写入 **`database.db`**（无单独 `matches` 文件夹）。

---

## 4. 稀疏重建（得到 3D 点与相机）

### 4.1 普通增量式重建（`mapper`）

```bash
cd /path/to/colmap_ws
mkdir -p sparse

env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap mapper \
  --database_path database.db \
  --image_path images \
  --output_path sparse \
  --Mapper.num_threads 4 \
  --Mapper.ba_global_images_freq 1000 \
  --Mapper.ba_global_points_freq 500000 \
  --Mapper.abs_pose_max_error 20 \
  --Mapper.abs_pose_min_inlier_ratio 0.15 \
  --Mapper.max_reg_trials 6
```

说明：

- **`mapper` 不要使用** `--SiftMatching.*`（该前缀仅用于 `feature_extractor` / `*_matcher`）。
- **`--Mapper.num_threads`**：适当减小可降低内存峰值，减轻 OOM。
- **`ba_global_*_freq`**：略增大可减少全局 BA 频率，有时减轻峰值内存（代价是优化节奏变化）。
- **`abs_pose_*` / `max_reg_trials`**：注册困难时可适度放宽（需自行权衡精度）。

输出在 **`sparse/0/`**（或 `1/`、`2/`…，取决于是否多模型、是否多次运行）。

### 4.2 超长序列可选：`hierarchical_mapper`

当图像很多、单次 `mapper` 易失败或内存不足时，可尝试分块合并式重建（参数见 `colmap hierarchical_mapper -h`）。

### 4.3 从已有模型续跑（可选）

仅在**明确要接着已有 `sparse/0` 增量注册**时使用：

```bash
colmap mapper \
  --database_path database.db \
  --image_path images \
  --input_path sparse/0 \
  --output_path sparse
```

若上次重建异常中断或几何很差，宜**备份后清空/重建 `sparse`**，再**不带** `--input_path` 从头跑。

---

## 5. 结果检查

```bash
colmap model_analyzer --path sparse/0
```

关注 **Registered images** 是否接近总图数、重投影误差是否合理。多模型时（`sparse/0`、`sparse/1`…）应对每个子目录分别检查；**主模型**一般是注册图像最多的那一套。

---

## 6. 常见问题

### 6.1 进程显示 `Killed`

多为 **内存不足（OOM）**。可：

- 在 Windows 用户目录配置 **`.wslconfig`** 增大 WSL 可用内存后执行 `wsl --shutdown` 再开 WSL；
- 减小 `--Mapper.num_threads`；
- 关闭其它占内存程序；
- 或使用 **`hierarchical_mapper`** 等分块策略。

### 6.2 Qt / `xcb` / `display` 报错

使用本文 **`env -u DISPLAY QT_QPA_PLATFORM=offscreen`** 组合；匹配阶段再加 **`--SiftMatching.use_gpu 0`**。

### 6.3 大量图像注册失败（`Could not register`）

常见于 **前向运动、基线小、纹理重复**。可尝试：加强序列匹配重叠、放宽 `Mapper.abs_pose_*`、或使用 **分层/先验**（若有 VO 位姿需查当前 COLMAP 版本是否支持相应流程）。

---

## 7. 可选：稠密点云（非 OpenSplat 必须）

若需要 **稠密** `.ply`，在已有 **`images/`** 与 **`sparse/0/`**（或你选定的主模型目录）上继续：

1. `image_undistorter`：去畸变并准备稠密工作区  
2. `patch_match_stereo`：块匹配  
3. `stereo_fusion`：融合为稠密点云  

命令与路径以 [COLMAP 官方文档](https://colmap.github.io/) 为准；该流程耗时长、占磁盘大。

---

## 8. 交给 OpenSplat 前

1. 确认 **`images/`** 与重建所用图像一致。  
2. 确认使用 **注册量足够** 的稀疏模型子目录（例如 `sparse/2/`）。  
3. 若下游工具**只认 `sparse/0/`**，可将主模型复制或软链为 `sparse/0`（注意备份原有 `0`）。  
4. 在 OpenSplat 工程根目录执行训练，例如：

```bash
/path/to/opensplat /path/to/colmap_ws -n 2000
```

（具体参数见 [OpenSplat](https://github.com/pierotofy/OpenSplat) 仓库说明。）

若 OpenSplat 报错 **`Unsupported camera model: 6`**（稀疏模型为 **FULL_OPENCV**），需先做 **去畸变**，输出为 **PINHOLE + 去畸变图**，见下一节脚本。

---

## 9. 去畸变 → PINHOLE（`image_undistorter`，脚本）

**作用**：在已有 **`images/`** 与 **`sparse/0/`** 上调用 COLMAP **`image_undistorter`**，生成 **`dense/`**（或自定义目录），其中：

- **`dense/images/`**：去畸变后的图像；
- **`dense/sparse/`**：与上面对应的稀疏模型，相机一般为 **PINHOLE** 或 **SIMPLE_PINHOLE**（以 COLMAP 导出为准）。

**一键脚本**（工程路径默认 `/home/ccxx/colmap_ws`）：

```bash
cd /home/ccxx/colmap_ws
chmod +x colmap_undistort_to_pinhole.sh
./colmap_undistort_to_pinhole.sh
```

默认会 **删除并重建** 工程下的 **`dense/`**，并在同目录生成 **`opensplat_input/`**（`images/` + `sparse/0/`，便于打包上传）。若只要 `dense`、不要打包目录：

```bash
PACK=0 ./colmap_undistort_to_pinhole.sh
```

自定义路径示例：

```bash
BASE=/home/ccxx/colmap_ws IMAGE_SUB=images SPARSE_SUB=sparse/0 DENSE_SUB=dense ./colmap_undistort_to_pinhole.sh
```

脚本内已使用 **`env -u DISPLAY QT_QPA_PLATFORM=offscreen`**，便于 WSL 无图形环境。

**注意**：训练 OpenSplat 时应使用 **`dense/images/`**（或 `opensplat_input/images/`）与 **`dense/sparse/`**（或 `opensplat_input/sparse/0/`），**不要**再与未去畸变的原 `images` 混用。

---

## 10. 命令速查（复制用）

```bash
# 顺序匹配（WSL 无头 + CPU 匹配）
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap sequential_matcher \
  --database_path database.db \
  --SequentialMatching.overlap 30 \
  --SequentialMatching.quadratic_overlap 1 \
  --SiftMatching.use_gpu 0

# 稀疏重建（示例参数）
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap mapper \
  --database_path database.db \
  --image_path images \
  --output_path sparse \
  --Mapper.num_threads 4 \
  --Mapper.ba_global_images_freq 1000 \
  --Mapper.ba_global_points_freq 500000

# 分析模型
colmap model_analyzer --path sparse/0
```

---

*文档对应流程：图像 →（特征）→ 匹配（`database.db`）→ 稀疏重建（`sparse/*/points3D.bin` 等）→（可选）去畸变 → PINHOLE → 再进入 OpenSplat。*

*去畸变脚本：`colmap_undistort_to_pinhole.sh`*
