import os
import glob
import subprocess
import shutil
from PIL import Image, ImageDraw, ImageFilter

BUILD_DIR = "build/gifs"
OUT_DIR = "assets"
os.makedirs(OUT_DIR, exist_ok=True)

# 与 Swift 中的 framed 保持完全一致的规格 (2x 坐标系)
# padX = 64, padY = 72, bar_w = 2008, bar_h = 60, corner_r = 36
padX, padY = 64, 72
bar_w, bar_h = 2008, 60
W, H = bar_w + padX * 2, bar_h + padY * 2
corner_r = 36

# 预先生成底板和遮罩
mask = Image.new("L", (W, H), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rounded_rectangle([padX, padY, padX + bar_w, padY + bar_h], radius=corner_r, fill=255)

shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
s_draw = ImageDraw.Draw(shadow)
s_draw.rounded_rectangle([padX, padY + 10, padX + bar_w, padY + bar_h + 10], radius=corner_r, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))

def process_video_to_gif(mov_path, out_gif_path, fps=15):
    temp_frames_dir = os.path.join(BUILD_DIR, "tmp_frames")
    temp_framed_dir = os.path.join(BUILD_DIR, "tmp_framed")
    shutil.rmtree(temp_frames_dir, ignore_errors=True)
    shutil.rmtree(temp_framed_dir, ignore_errors=True)
    os.makedirs(temp_frames_dir, exist_ok=True)
    os.makedirs(temp_framed_dir, exist_ok=True)

    # 1. ffmpeg 抽帧
    subprocess.run([
        "ffmpeg", "-y", "-i", mov_path,
        "-vf", f"fps={fps}",
        os.path.join(temp_frames_dir, "frame_%04d.png")
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    # 2. 批量加外框
    frame_files = sorted(glob.glob(os.path.join(temp_frames_dir, "frame_*.png")))
    if not frame_files:
        print(f"Warning: no frames found for {mov_path}")
        return

    for idx, fpath in enumerate(frame_files):
        raw = Image.open(fpath).convert("RGBA")
        if raw.size != (bar_w, bar_h):
            raw = raw.resize((bar_w, bar_h), Image.LANCZOS)
        
        comp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        comp.paste(shadow, (0, 0), shadow)
        comp.paste(raw, (padX, padY), mask.crop((padX, padY, padX + bar_w, padY + bar_h)))
        b_draw = ImageDraw.Draw(comp)
        b_draw.rounded_rectangle([padX, padY, padX + bar_w, padY + bar_h], radius=corner_r, outline=(66, 66, 66, 255), width=2)
        
        comp.save(os.path.join(temp_framed_dir, f"frame_{idx:04d}.png"))

    # 3. ffmpeg 转高质量 GIF (palettegen + paletteuse)
    palette_path = os.path.join(BUILD_DIR, "palette.png")
    subprocess.run([
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", os.path.join(temp_framed_dir, "frame_%04d.png"),
        "-vf", "palettegen=max_colors=128:reserve_transparent=1",
        palette_path
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    subprocess.run([
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", os.path.join(temp_framed_dir, "frame_%04d.png"),
        "-i", palette_path,
        "-lavfi", "paletteuse=dither=bayer:bayer_scale=3",
        "-loop", "0",
        out_gif_path
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    print(f"Wrote GIF: {out_gif_path} ({os.path.getsize(out_gif_path) // 1024} KB)")
    shutil.rmtree(temp_frames_dir, ignore_errors=True)
    shutil.rmtree(temp_framed_dir, ignore_errors=True)

for name in ["idle", "spring", "summer", "autumn", "winter"]:
    mov = os.path.join(BUILD_DIR, f"{name}.mov")
    if os.path.exists(mov):
        out_gif = os.path.join(OUT_DIR, f"touchbar-{name}.gif")
        process_video_to_gif(mov, out_gif)

# 制作四季合辑 touchbar-seasons.gif
# 将四个季节的帧在垂直方向上叠在一起
seasons = ["spring", "summer", "autumn", "winter"]
season_movs = [os.path.join(BUILD_DIR, f"{s}.mov") for s in seasons]
if all(os.path.exists(m) for m in season_movs):
    print("==> 正在合成四季合辑 touchbar-seasons.gif ...")
    temp_frames_dir = os.path.join(BUILD_DIR, "tmp_seasons_frames")
    temp_framed_dir = os.path.join(BUILD_DIR, "tmp_seasons_framed")
    shutil.rmtree(temp_frames_dir, ignore_errors=True)
    shutil.rmtree(temp_framed_dir, ignore_errors=True)
    os.makedirs(temp_frames_dir, exist_ok=True)
    os.makedirs(temp_framed_dir, exist_ok=True)

    fps = 15
    for s in seasons:
        s_dir = os.path.join(temp_frames_dir, s)
        os.makedirs(s_dir, exist_ok=True)
        subprocess.run([
            "ffmpeg", "-y", "-i", os.path.join(BUILD_DIR, f"{s}.mov"),
            "-vf", f"fps={fps}",
            os.path.join(s_dir, "frame_%04d.png")
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    min_count = min(len(glob.glob(os.path.join(temp_frames_dir, s, "frame_*.png"))) for s in seasons)
    
    # 拼垂直 stack
    pad_between = 24
    total_H = H * 4 + pad_between * 3
    for idx in range(min_count):
        combined = Image.new("RGBA", (W, total_H), (0, 0, 0, 0))
        y_offset = 0
        for s in seasons:
            fpath = os.path.join(temp_frames_dir, s, f"frame_{idx+1:04d}.png")
            raw = Image.open(fpath).convert("RGBA")
            if raw.size != (bar_w, bar_h):
                raw = raw.resize((bar_w, bar_h), Image.LANCZOS)
            
            comp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            comp.paste(shadow, (0, 0), shadow)
            comp.paste(raw, (padX, padY), mask.crop((padX, padY, padX + bar_w, padY + bar_h)))
            b_draw = ImageDraw.Draw(comp)
            b_draw.rounded_rectangle([padX, padY, padX + bar_w, padY + bar_h], radius=corner_r, outline=(66, 66, 66, 255), width=2)
            
            combined.paste(comp, (0, y_offset), comp)
            y_offset += H + pad_between

        combined.save(os.path.join(temp_framed_dir, f"frame_{idx:04d}.png"))

    out_seasons_gif = os.path.join(OUT_DIR, "touchbar-seasons.gif")
    palette_path = os.path.join(BUILD_DIR, "palette_seasons.png")
    subprocess.run([
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", os.path.join(temp_framed_dir, "frame_%04d.png"),
        "-vf", "palettegen=max_colors=128:reserve_transparent=1",
        palette_path
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    subprocess.run([
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", os.path.join(temp_framed_dir, "frame_%04d.png"),
        "-i", palette_path,
        "-lavfi", "paletteuse=dither=bayer:bayer_scale=3",
        "-loop", "0",
        out_seasons_gif
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    print(f"Wrote GIF: {out_seasons_gif} ({os.path.getsize(out_seasons_gif) // 1024} KB)")
    shutil.rmtree(temp_frames_dir, ignore_errors=True)
    shutil.rmtree(temp_framed_dir, ignore_errors=True)
