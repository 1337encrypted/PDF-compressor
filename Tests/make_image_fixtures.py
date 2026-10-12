"""Synthetic images for frame, transparency, size, and EXIF checks."""
from pathlib import Path
import random
import sys
from PIL import Image, ImageDraw, features

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
rng = random.Random(17)
photo = Image.frombytes("RGB", (960, 640), rng.randbytes(960 * 640 * 3))
photo.save(root / "photo.jpg", quality=100, subsampling=0)
exif = Image.Exif()
exif[274] = 6
photo.save(root / "rotated.jpg", quality=100, subsampling=0, exif=exif)
photo.save(root / "photo.bmp")
photo.save(root / "photo.webp", lossless=True)
photo.save(root / "photo.tiff", compression="raw")
if features.check("avif"):
    photo.save(root / "photo.avif", quality=100, subsampling="4:4:4")

transparent = Image.new("RGBA", (960, 640), (0, 0, 0, 0))
draw = ImageDraw.Draw(transparent)
draw.rounded_rectangle((120, 100, 840, 540), radius=50, fill=(12, 120, 185, 210))
draw.rectangle((280, 240, 680, 400), fill=(240, 248, 250, 255))
transparent.save(root / "transparent.png", compress_level=0)
transparent.save(root / "transparent.webp", lossless=True)
transparent.save(root / "tiny.png", optimize=True)

red = Image.new("RGB", (480, 320), "red")
blue = Image.new("RGB", (480, 320), "blue")
red.save(root / "animated.gif", save_all=True, append_images=[blue], duration=[120, 240], loop=2, disposal=2)
red.save(root / "animated.png", save_all=True, append_images=[blue], duration=[120, 240], loop=2, compress_level=0)
red.save(root / "multipage.tiff", save_all=True, append_images=[blue], compression="raw")
(root / "broken.png").write_bytes(b"this is not a PNG")
print(f"Created image fixtures in {root}")
