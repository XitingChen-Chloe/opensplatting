# OpenSplatting Technical Report: From COLMAP Sparse Reconstruction to OpenSplat Training

This document summarizes the project workflow ([opensplatting](https://github.com/XitingChen-Chloe/opensplatting)–related notes) and covers the end-to-end pipeline on **WSL2**: **COLMAP → (optional) undistortion / image compression → OpenSplat (Docker + CUDA)**.

---

## 1. Abstract

In a **WSL2** environment, **COLMAP** recovers camera poses and sparse 3D points from RGB images; **OpenSplat** then trains a **3D Gaussian Splatting** model, producing `splat.ply` and `cameras.json`. This report covers: sparse reconstruction, model validation, (optional) undistortion for PINHOLE compatibility, (optional) image compression, Docker image build and training, and common troubleshooting.

---

## 2. Goals and I/O

| Stage | Input | Output |
|------|------|------|
| COLMAP | `images/`, (optional) new `database.db` | `database.db`, `sparse/0/` (or `1/`, …) |
| Undistortion (if needed) | `images/` + `sparse/0/` | `dense/images/`, `dense/sparse/`, or packaged `opensplat_input/` |
| OpenSplat | `images/` + `sparse/<model>/` | `splat.ply`, `cameras.json`, optional intermediate `splat_<steps>.ply` |

**Note:** OpenSplat requires a **sparse model and images consistent with it**. Dense MVS is **not** a hard prerequisite for OpenSplat.

---

## 3. Environment and Toolchain

- **WSL2:** For large datasets, prefer an ext4 home directory to reduce cross-filesystem I/O.
- **COLMAP:** `colmap --version`; use CPU paths (`use_gpu 0`) when CUDA is unavailable.
- **Docker:** `docker version` works; GPU requires `docker run --gpus all` and a working NVIDIA driver on the host.
- **OpenSplat:** Typically build locally with `docker build` (e.g. `opensplat:latest`); binary inside the container: `/code/build/opensplat`.

---

## 4. Standard Directory Layout (COLMAP Project)

```text
colmap_ws/
├── images/           # RGB images; filenames must match DB / model
├── database.db       # Features, matches, metadata
└── sparse/           # mapper output
    └── 0/            # primary model (or 1, 2, …)
```

If `database.db` does not exist yet, run feature extraction first. If you copy an existing database that already contains matches, you may skip extraction and go straight to matching or reconstruction, depending on the data.

---

## 5. Pipeline A: COLMAP Sparse Reconstruction

### 5.1 Feature Extraction

```bash
cd /path/to/colmap_ws
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap feature_extractor \
  --database_path database.db \
  --image_path images
```

For CPU-only COLMAP, add: `--SiftExtraction.use_gpu 0` (confirm with `colmap feature_extractor -h`).

### 5.2 Feature Matching

| Data type | Recommendation |
|-----------|----------------|
| Video / ordered sequence | `sequential_matcher` |
| Unordered / orbit | `exhaustive_matcher` or `vocab_tree_matcher` |

**Sequential matching example (headless WSL + CPU matching):**

```bash
env -u DISPLAY QT_QPA_PLATFORM=offscreen colmap sequential_matcher \
  --database_path database.db \
  --SequentialMatching.overlap 30 \
  --SequentialMatching.quadratic_overlap 1 \
  --SiftMatching.use_gpu 0
```

- `env -u DISPLAY`: avoids Qt errors from an invalid `DISPLAY`.
- `QT_QPA_PLATFORM=offscreen`: runs without a window.
- Matches are stored in **`database.db`**; there is no separate `matches/` folder.

### 5.3 Incremental Reconstruction (`mapper`)

```bash
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

**Important:** Do **not** pass `--SiftMatching.*` to `mapper` (those flags apply only to `feature_extractor` / `*_matcher`).

**Very long sequences:** try `hierarchical_mapper` (see `colmap hierarchical_mapper -h`).

**Resume from an existing model** (only when you intentionally continue incremental registration):

```bash
colmap mapper \
  --database_path database.db \
  --image_path images \
  --input_path sparse/0 \
  --output_path sparse
```

If the previous run crashed or geometry is poor, back up and clear `sparse`, then rerun **without** `--input_path`.

### 5.4 Quality Check

```bash
colmap model_analyzer --path sparse/0
```

Check whether **Registered images** is close to the total image count and whether reprojection error is reasonable. For multiple models (`sparse/0`, `sparse/1`, …), inspect each; **pick the model with the most registered images** as the primary one.

---

## 6. Pre–OpenSplat Checklist

1. `images/` matches the images used for reconstruction.
2. Use a `sparse/<id>/` with enough registered views.
3. If downstream tools only accept `sparse/0/`, copy or symlink the primary model to `sparse/0/` (back up first).
4. If OpenSplat reports an **unsupported camera model** (e.g. **FULL_OPENCV** in the sparse model), run undistortion first to obtain **PINHOLE / SIMPLE_PINHOLE** and undistorted images (next section).

---

## 7. Pipeline B: Undistortion → PINHOLE (`image_undistorter`)

**Purpose:** Given `images/` and `sparse/0/`, run `image_undistorter` to typically produce:

- `dense/images/`: undistorted images
- `dense/sparse/`: matching sparse model (cameras usually PINHOLE family)

If your project includes a one-shot script (e.g. `colmap_undistort_to_pinhole.sh`), typical usage:

```bash
cd /home/ccxx/colmap_ws
chmod +x colmap_undistort_to_pinhole.sh
./colmap_undistort_to_pinhole.sh
```

- By default the script may delete and recreate `dense/` and emit `opensplat_input/` (`images/` + `sparse/0/`) for packaging.
- Dense only, no package: `PACK=0 ./colmap_undistort_to_pinhole.sh`
- Custom paths: pass `BASE`, `IMAGE_SUB`, `Sparse_SUB`, `DENSE_SUB`, etc. as environment variables.

**Rule:** For OpenSplat training, **undistorted images** must be paired with the **undistorted sparse** model; **do not** mix them with original distorted images.

---

## 8. Pipeline C: Image Compression (Upload / Size Limits)

When compressing images **without** changing `sparse` geometry files, you must keep:

- **Filenames (including extension) unchanged**
- **Resolution (width × height) unchanged**

Otherwise projection and training will be misaligned.

### 8.1 Which Folder to Compress?

| Stage | Recommendation |
|-------|----------------|
| After undistortion, ready for OpenSplat | Compress `dense/images/` or `opensplat_input/images/` together with the matching `sparse` |
| COLMAP only, not undistorted | Compressing `images/` must match the current `sparse` reconstruction; safest to finalize `sparse` before compressing images |

### 8.2 Option 1: `compress_images.py` (Pillow)

After setting `BASE`, `SRC`, `DST` in the script:

```bash
pip3 install --user pillow
python3 /path/to/colmap_ws/compress_images.py
```

JPEG: adjust quality; PNG: often lossless optimization with limited size reduction.

### 8.3 Option 2: `pngquant_images.sh` (lossy PNG)

Install: `sudo apt install -y pngquant`.  
Use `BASE`, `SRC_NAME`, `DST_NAME`, `COLORS`, etc. to select folders and palette size.

### 8.4 If Still Too Large

- Lower `COLORS` or JPEG quality slightly.
- **Frame dropping** requires **re-running COLMAP**; you cannot delete images and keep the old model.
- Request a larger upload quota or split archives.

If present in the repo, see `WSL_图像压缩说明.md` for more detail.

---

## 9. Pipeline D: OpenSplat (WSL2 + Docker)

### 9.1 Build the Image

```bash
cd ~
git clone https://github.com/pierotofy/OpenSplat.git
cd OpenSplat
docker build -t opensplat:latest .
```

If build fails on newer GPUs, specify CUDA architectures, e.g.:

```bash
docker build -t opensplat:latest \
  --build-arg CMAKE_CUDA_ARCHITECTURES="75;80;86;89" \
  .
```

### 9.2 Mount Paths

- WSL example: `/home/ccxx/colmap_ws/opensplat_input`
- Windows drive: `D:\colmap` → `/mnt/d/colmap`

For long training runs, prefer WSL ext4 storage.

### 9.3 Run Training (Example)

Replace the username/path with your actual WSL user:

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

Outputs typically include: `splat_*.ply`, `cameras.json`; with `--save-every`, intermediate `splat_<step>.ply` files.

To use a custom image subdirectory (not default `images/`), use `--colmap-image-path` per your OpenSplat version’s `./opensplat --help`.

### 9.4 Help

```bash
docker run --rm opensplat:latest bash -lc 'cd /code/build && ./opensplat --help'
```

Common flags: `-n` iterations, `-d` downscale, `--densify-grad-thresh` densification strength, `--resume` continue from a PLY, etc.

### 9.5 Tuning (Reduce Floaters / Large Halos, Optional)

On top of a baseline command, try individually:

- Increase `--densify-grad-thresh` (fewer spurious Gaussians in the background)
- Increase `--reset-alpha-every` (less frequent opacity resets that can “revive” artifacts)
- Decrease `--split-screen-size` (suppress oversized splats)

Tune values empirically for your data and VRAM.

### 9.6 Viewing and Post-Processing

Use a common Splat viewer or editor for `splat.ply` (per course or toolchain).

---

## 10. Pipeline E (Optional): COLMAP Dense Reconstruction

For a dense `.ply`, continue from `images/` and a chosen `sparse/`: `image_undistorter` → `patch_match_stereo` → `stereo_fusion`.  
This is slow and disk-heavy; **OpenSplat does not require it**. See the [COLMAP documentation](https://colmap.github.io/).

---

## 11. Troubleshooting Summary

| Symptom | What to try |
|---------|-------------|
| Process `Killed` | OOM: increase WSL memory (`.wslconfig` + `wsl --shutdown`), lower `Mapper.num_threads`, or use `hierarchical_mapper` |
| Qt / xcb / display | `env -u DISPLAY QT_QPA_PLATFORM=offscreen`; for matching, `SiftMatching.use_gpu 0` |
| Many `Could not register` | Small baseline / weak texture: increase sequence overlap, relax `abs_pose_*`, or hierarchical / prior workflows |
| Docker has no GPU | Enable Docker Desktop WSL integration + GPU; or install `nvidia-container-toolkit` |
| GPU OOM | Increase `-d` (e.g. 2→4), reduce iterations or adjust other params |
| Missing images / `Cannot read` | Match `images` path and COLMAP records; same extensions; `--colmap-image-path` if needed |
| CUDA illegal memory access, etc. | Lower `-d` to test stability; check image channels/decoding; use `CUDA_LAUNCH_BLOCKING=1` for debugging (see PyTorch/CUDA docs) |

---

## 12. End-to-End Summary

1. Prepare `images/`; create and fill `database.db` if needed (feature extraction).
2. Feature matching (e.g. `sequential_matcher` for sequences).
3. Run `mapper` → `sparse/<id>/`; use `model_analyzer` to choose the primary model.
4. If the camera model is incompatible with OpenSplat: undistort to PINHOLE + new images, with matching `sparse`.
5. (Optional) Compress images without changing resolution or filenames.
6. `docker build` OpenSplat, `docker run --gpus all`, mount the project, run `./opensplat`.
7. Collect `splat.ply`, `cameras.json`, and optional validation render directory from the output location.

---

## 13. References

- OpenSplat: https://github.com/pierotofy/OpenSplat  
- COLMAP: https://colmap.github.io/  
- Project notes repo (if applicable): https://github.com/XitingChen-Chloe/opensplatting  

---

*English version: `colmap_ws/OPEN_SPLATTING_REPORT_EN.md`. Chinese version: `colmap_ws/OPEN_SPLATTING_REPORT.md`. Replace local paths and usernames with your environment.*
