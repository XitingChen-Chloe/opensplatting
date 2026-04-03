#!/usr/bin/env python3
"""批量压图：JPEG 降质量，PNG 用 zlib 压缩。输出文件名与输入完全一致。"""
from pathlib import Path
from PIL import Image

# 按你的路径修改（下面示例为 WSL 下的 colmap_ws）
SRC = Path("/home/ccxx/colmap_ws/images")
DST = Path("/home/ccxx/colmap_ws/images_small")
JPEG_QUALITY = 82
PNG_COMPRESS = 9

DST.mkdir(parents=True, exist_ok=True)

for p in sorted(SRC.iterdir()):
    if not p.is_file():
        continue
    suf = p.suffix.lower()
    if suf not in (".jpg", ".jpeg", ".png", ".bmp", ".webp"):
        continue
    out = DST / p.name
    try:
        im = Image.open(p)
        if im.mode in ("RGBA", "P") and suf in (".jpg", ".jpeg"):
            im = im.convert("RGB")
        if suf in (".jpg", ".jpeg"):
            im.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)
        elif suf == ".png":
            im.save(out, "PNG", optimize=True, compress_level=PNG_COMPRESS)
        else:
            im.save(out)
        print(p.name, "->", out.stat().st_size // 1024, "KB")
    except Exception as e:
        print("SKIP", p, e)

print("Done. 检查无误后，用 images_small 打包上传；确认可用再删原图。")
