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
