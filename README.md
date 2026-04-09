# opensplatting

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
    └── 0/            # 或其它编号
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

## 10. 压缩图像（减小体积、便于上传）

上传平台有 **大小限制**（例如 2GB）或需节省空间时，可在 **不动稀疏几何文件** 的前提下，只对 **图像目录** 做压缩。**前提**：与当前使用的 **`sparse` / 相机** 一致——**文件名（含扩展名）不变**，**宽高（分辨率）不变**；否则投影与训练会错位。

### 10.1 该压哪一套目录？

| 阶段 | 建议压缩对象 |
|------|----------------|
| 已做 **§9 去畸变**、准备给 OpenSplat | 压 **`dense/images/`**（或已拷好的 **`opensplat_input/images/`**），并与 **`dense/sparse/`**（或 **`opensplat_input/sparse/0/`**）成对使用 |
| 仅 COLMAP、尚未去畸变 | 压 **`images/`** 时须与对应 **`sparse`** 为同一重建；更稳妥是 **压图前已定稿 sparse**，且 **不重跑 mapper** 时只替换像素内容 |

**不要**：把 **去畸变后的图** 与 **未去畸变的 sparse** 混用，或改分辨率后仍用旧 `cameras.bin`。

### 10.2 方式一：`compress_images.py`（Pillow，偏无损/轻量）

脚本：`colmap_ws/compress_images.py`。编辑其中 **`BASE`、`SRC`、`DST`**，例如从原图到 `images_small`：

```python
BASE = Path("/home/ccxx/colmap_ws")
SRC = BASE / "images"
DST = BASE / "images_small"
```

对 **去畸变图** 可改为 `SRC = BASE / "dense/images"`，`DST = BASE / "dense/images_small"` 等。

```bash
pip3 install --user pillow
python3 /home/ccxx/colmap_ws/compress_images.py
```

- **JPEG**：降低 `JPEG_QUALITY` 可明显减小体积。  
- **PNG**：主要为无损优化，**体积降幅通常有限**（照片类 PNG 仍很大）。

### 10.3 方式二：`pngquant_images.sh`（有损 PNG，体积常明显下降）

需先安装：`sudo apt install -y pngquant`。

脚本：`colmap_ws/pngquant_images.sh`。默认从 **`images_small`** 生成 **`images_pngquant`**；可通过环境变量改输入/输出目录，例如对 **去畸变图** 生成 `dense/images_lq`：

```bash
cd /home/ccxx/colmap_ws
chmod +x pngquant_images.sh
BASE=/home/ccxx/colmap_ws SRC_NAME=dense/images DST_NAME=dense/images_lq ./pngquant_images.sh
```

可选 **`COLORS`**（默认 `256`，更小可试 `128`）：

```bash
COLORS=128 BASE=/home/ccxx/colmap_ws SRC_NAME=dense/images DST_NAME=dense/images_lq ./pngquant_images.sh
```

完成后用 **`dense/images_lq`** 作为上传用的 **`images`**（或将其中文件覆盖到 **`opensplat_input/images/`**），**`sparse` 仍用与去畸变配套的那一份**。

### 10.4 体积仍过大时

- 在 **pngquant** 基础上再略降 **`COLORS`**，或  
- **抽帧**（图变少）需 **重做 COLMAP 稀疏重建**，不能仅删图不换模型；或  
- 向课程方申请 **更大上传限额 / 分卷**。

更细的说明（含常见问题）见同目录 **`WSL_图像压缩说明.md`**。

---

## 11. 命令速查（复制用）

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

*文档对应流程：图像 →（特征）→ 匹配（`database.db`）→ 稀疏重建（`sparse/*/points3D.bin` 等）→（可选）去畸变 → PINHOLE →（可选）压缩图像 → 再进入 OpenSplat。*

*脚本：`colmap_undistort_to_pinhole.sh`（去畸变）、`compress_images.py` / `pngquant_images.sh`（压图）；压图详解见 `WSL_图像压缩说明.md`。*
）→ 稀疏重建（`sparse/*/points3D.bin` 等）→（可选）去畸变 → PINHOLE → 再进入 OpenSplat。*

*去畸变脚本：`colmap_undistort_to_pinhole.sh`*

# OpenSplat：WSL2 + Docker 全流程说明

本文说明在 WSL2 中通过 Docker 使用 [OpenSplat](https://github.com/pierotofy/OpenSplat) 的完整流程：从准备 Docker、构建镜像，到挂载 COLMAP 工程、训练输出与常用调参。

---

## 前置条件

- **WSL2**（任意常见 Linux 发行版）。
- **NVIDIA GPU**：CUDA 版镜像需要主机已安装 **Windows 或 WSL 下的 NVIDIA 驱动**，且 Docker 能使用 GPU（Docker Desktop 开启 GPU 支持，或 Linux 下安装 `nvidia-container-toolkit`）。
- **COLMAP 工程**：需包含 **相机位姿 + 稀疏点**，不能只依赖随机初始化。典型目录结构：
  - `images/`：原始照片
  - `sparse/0/`（或类似）：`cameras.bin`、`images.bin`、`points3D.bin` 等

---

## 第一步：在 WSL 中确保 `docker` 可用

若执行 `docker version` 报错 `command not found`：

**方式 A（常见）**  
在 Windows 安装 [Docker Desktop](https://www.docker.com/products/docker-desktop/)，在 **Settings → Resources → WSL integration** 中为当前发行版勾选 **Enable integration**。  
参考：[Docker Desktop 与 WSL 2](https://docs.docker.com/go/wsl2/)

**方式 B**  
在 WSL 内安装 Docker Engine（例如 `sudo apt install docker.io`），并将用户加入 `docker` 组。

---

## 第二步：获取 OpenSplat 源码并构建镜像

官方仓库通常**不提供**可直接 `docker pull` 的固定镜像名，需在本地 **构建**（默认 `Dockerfile` 为 **CUDA**）。

```bash
cd ~
git clone https://github.com/pierotofy/OpenSplat.git
cd OpenSplat
docker build -t opensplat .
```

**显卡较新**（如 RTX 40 系）若编译报错，可指定 CUDA 架构，例如：

```bash
docker build -t opensplat \
  --build-arg CMAKE_CUDA_ARCHITECTURES="75;80;86;89" \
  .
```

构建完成后，镜像名为 **`opensplat`**，可执行文件在容器内路径：**`/code/build/opensplat`**。

---

## 第三步：准备数据路径

### 数据放在 WSL 家目录（示例：`~/colmap`）

假设 COLMAP 工程在 WSL 中为：

```text
/home/你的用户名/colmap/
  images/
  sparse/
```

### 数据在 Windows D 盘

WSL 中对应前缀为 **`/mnt/d/`**，例如：

```text
D:\colmap  →  /mnt/d/colmap
```

可将 `images`、`sparse` 复制到 `~/colmap`，或直接从 `/mnt/d/colmap` 挂载（大项目长期训练更推荐放在 WSL 的 ext4 家目录以减少 I/O 问题，按实际情况选择）。

---

## 第四步：运行 OpenSplat（Docker）

### 4.1 输入在 WSL，输出也在 WSL

```bash
docker run --gpus all --rm -it \
  -v /home/你的用户名/colmap:/data/scene \
  -v /home/你的用户名/colmap/out:/data/out \
  opensplat \
  bash -lc 'cd /code/build && ./opensplat /data/scene -n 30000 -o /data/out/splat.ply -d 1 --save-every 3000'
```

- **`/data/scene`**：COLMAP 工程根目录（其下需有 `images`、`sparse`）。
- **`/data/out`**：输出目录；会生成 **`splat.ply`**，以及 **`cameras.json`**（与 `splat.ply` 同目录）。

将 `你的用户名` 换成实际 WSL 用户名（例如 `ccxx`）。

### 4.2 输出到 Windows 文件夹（例如 `D:\colmap\outcome\run1`）

先创建目录，再挂载：

```bash
mkdir -p /mnt/d/colmap/outcome/run1

docker run --gpus all --rm -it \
  -v /home/你的用户名/colmap:/data/scene \
  -v /mnt/d/colmap/outcome/run1:/data/out \
  opensplat \
  bash -lc 'cd /code/build && ./opensplat /data/scene -n 30000 -o /data/out/splat.ply -d 1 --save-every 3000'
```

Windows 侧路径：**`D:\colmap\outcome\run1\splat.ply`**、**`cameras.json`**。  
若使用 **`--save-every`**，还会生成 **`splat_3000.ply`、`splat_6000.ply`** 等中间结果。

### 4.3 输入直接使用 D 盘 COLMAP 工程

```bash
docker run --gpus all --rm -it \
  -v /mnt/d/colmap:/data/scene \
  -v /mnt/d/colmap/outcome/run1:/data/out \
  opensplat \
  bash -lc 'cd /code/build && ./opensplat /data/scene -n 30000 -o /data/out/splat.ply -d 1'
```

---

## 第五步：查看帮助与常用参数

```bash
docker run --rm opensplat bash -lc 'cd /code/build && ./opensplat --help'
```

| 参数 | 含义（简要） |
|------|----------------|
| `-n` / `--num-iters` | 迭代次数 |
| `-d` / `--downscale-factor` | **1** = 不缩小原图；**2** = 宽高各约 1/2，省显存 |
| `-o` / `--output` | 输出 `ply` 路径（`cameras.json` 写在同目录） |
| `--save-every` | 每 N 步额外保存 `splat_<步数>.ply`（`-1` 关闭） |
| `--densify-grad-thresh` | 增密梯度阈值；**调大**通常增密更少，可减轻浮点 |
| `--resume` | 从已有 `ply` 继续训练 |

多分辨率、球谐、`refine-every` 等见 `--help` 全文。

调参优化
```bash
docker run --gpus all --rm -it \
  -v /home/ccxx/colmap_ws/opensplat_input:/data/scene \
  opensplat:latest \
  bash -lc 'cd /code/build && ./opensplat /data/scene \
    -n 22000 \
    -d 2 \
    --densify-grad-thresh 0.0003 \
    --refine-every 150 \
    --warmup-length 800 \
    --reset-alpha-every 40 \
    --stop-screen-size-at 3000 \
    --ssim-weight 0.15 \
    --save-every 2000 \
    --val \
    --val-render /data/scene/val_d2_opt \
    -o /data/scene/splat_22000_d2_opt.ply'
```
Stricter densify, More frequent refine, More frequent alpha resets
```bash
docker run --gpus all --rm -it \
  -v /home/ccxx/colmap_ws/opensplat_input:/data/scene \
  opensplat:latest \
  bash -lc 'cd /code/build && ./opensplat /data/scene \
    -n 20000 \
    -d 2 \
    --densify-grad-thresh 0.0004 \
    --refine-every 100 \
    --warmup-length 700 \
    --reset-alpha-every 28 \
    --stop-screen-size-at 2500 \
    --split-screen-size 0.04 \
    --ssim-weight 0.15 \
    --save-every 2000 \
    --val \
    --val-render /data/scene/val_d2_v2 \
    -o /data/scene/splat_20000_d2_v2.ply'
```
---

## 第六步：查看与后期

- 浏览器查看示例：[PlayCanvas Viewer](https://playcanvas.com/viewer)、编辑浮点：[SuperSplat](https://playcanvas.com/supersplat/editor)。
- 若画面像「平面地图」：尝试 **斜视/低机位** 浏览；航拍正射多时，可 **补拍倾斜角度** 改善高度感。

---

## 故障排查简表

| 现象 | 处理方向 |
|------|----------|
| `docker` 找不到 | Docker Desktop WSL 集成或本机安装 Docker |
| 显存不足 | 使用 `-d 2` 或更大 downscale；或减少迭代、调参 |
| 训练报错找不到图像 | 检查 `images` 路径与 COLMAP 中记录是否一致，必要时试 `--colmap-image-path` |
| AMD GPU | 需使用仓库内 **ROCm** 相关 `Dockerfile` 单独构建，运行方式见 [OpenSplat README](https://github.com/pierotofy/OpenSplat) |

---

## 流程小结

1. WSL 内 **`docker` 可用** → `git clone` OpenSplat → **`docker build -t opensplat .`**  
2. 准备好 **`images` + `sparse`** 的 COLMAP 工程目录  
3. **`docker run --gpus all`**，**`-v 工程:/data/scene`**，**`-v 输出目录:/data/out`**  
4. 执行 **`./opensplat /data/scene -o /data/out/splat.ply ...`**  
5. 在输出目录取 **`splat.ply`**、**`cameras.json`**（及可选的中间 `splat_*.ply`）

---

*文档随本地路径举例编写，请将 `你的用户名`、盘符与目录名替换为实际环境。*

