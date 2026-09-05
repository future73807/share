#!/usr/bin/env python3
"""生成应用图标:Android 自适应图标(前景/背景/遗留 PNG)+ Web favicon。

用法:python scripts/make_icons.py
设计:蓝色对角渐变背景 + 白色"显示器+向上箭头"(屏幕共享)图形。
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'app', 'android', 'app', 'src', 'main', 'res')
PUB = os.path.join(ROOT, 'public')
S = 2048  # 主画布(超采样)

C1 = (77, 175, 245, 255)   # 浅蓝 #4DAFF5
C2 = (18, 92, 180, 255)    # 深蓝 #125CB4
WHITE = (255, 255, 255, 255)

# 各密度尺寸
LEGACY = [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]
ADAPTIVE = [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)]


def gradient(size):
    """对角渐变:左上浅蓝 → 右下深蓝。"""
    small = 256
    mask = Image.new('L', (small, small))
    px = mask.load()
    for y in range(small):
        for x in range(small):
            px[x, y] = int(255 * (x + y) / (2 * (small - 1)))
    mask = mask.resize((size, size), Image.BILINEAR)
    light = Image.new('RGBA', (size, size), C1)
    dark = Image.new('RGBA', (size, size), C2)
    return Image.composite(light, dark, mask)


def draw_glyph(draw, s, k=1.0, color=WHITE):
    """白色图形:笔记本电脑侧视,屏幕内有向右共享箭头(品牌 logo)。"""
    def u(x, y):
        off = s * (1 - k) / 2
        return (off + x * s * k, off + y * s * k)

    sw = max(3, int(0.048 * s * k))

    # ── 屏幕:描边圆角矩形 ──
    draw.rounded_rectangle([u(0.24, 0.20), u(0.76, 0.60)],
                           radius=0.035 * s * k, outline=color, width=sw)

    # ── 屏幕内向右共享箭头(实心:杆 + 三角头) ──
    draw.rounded_rectangle([u(0.34, 0.355), u(0.50, 0.445)],
                           radius=0.02 * s * k, fill=color)
    draw.polygon([u(0.49, 0.30), u(0.49, 0.50), u(0.635, 0.40)], fill=color)

    # ── 底座:实心梯形(左低右高微透视,简化为圆角矩形) ──
    draw.polygon([u(0.30, 0.62), u(0.70, 0.62), u(0.76, 0.72), u(0.24, 0.72)],
                 fill=color)


def make_legacy(size):
    """完整方形图标(圆角),用于 API<26 启动器与 Web favicon。"""
    img = gradient(size)
    draw = ImageDraw.Draw(img)
    draw_glyph(draw, size)
    # 圆角遮罩
    mask = Image.new('L', (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle([0, 0, size - 1, size - 1], radius=0.22 * size, fill=255)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def make_foreground(size):
    """自适应图标前景:透明底,图形居中于安全区(约 58%)。"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_glyph(draw, size, k=0.60)
    return img


def make_background(size):
    """自适应图标背景:满幅渐变(启动器自行裁形)。"""
    return gradient(size)


def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)
    print('写入', os.path.relpath(path, ROOT))


def main():
    # Android 遗留图标
    for dpi, size in LEGACY:
        save(make_legacy(S), os.path.join(RES, f'mipmap-{dpi}', 'ic_launcher.png'), size)
    # Android 自适应图标
    for dpi, size in ADAPTIVE:
        save(make_foreground(S), os.path.join(RES, f'drawable-{dpi}', 'ic_launcher_foreground.png'), size)
        save(make_background(S), os.path.join(RES, f'drawable-{dpi}', 'ic_launcher_background.png'), size)
    # Web favicon
    save(make_legacy(S), os.path.join(PUB, 'favicon.png'), 512)
    print('完成')


if __name__ == '__main__':
    main()
