#!/usr/bin/env python3
# 生成 Quadro 应用图标
# 概念: 黑曜石底 + 2x2 四象限 + 电光钛蓝焦点窗格 + 极光青渐变 + 右下 Q 尾巴
# 输出: Quadro.iconset/ 下的各尺寸 PNG,以及 icon-preview.png 预览图

from PIL import Image, ImageDraw, ImageFilter
import os

S = 1024

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def v_gradient(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=lerp(top, bottom, t))
    return img

# 1. 画布
base = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 2. 底板(近似 squircle 的大圆角矩形)
squircle_box = (40, 40, S - 40, S - 40)
squircle_radius = int((S - 80) * 0.245)

grad = v_gradient(S, S, (23, 27, 34), (11, 13, 16))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(squircle_box, radius=squircle_radius, fill=255)
base.paste(grad, (0, 0), mask)

bd = ImageDraw.Draw(base)
# 1px 冷白倒角高光
bd.rounded_rectangle(squircle_box, radius=squircle_radius, outline=(255, 255, 255, 22), width=2)

# 3. Q4 焦点窗格光晕(先画,在 chambers 之下)
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).rounded_rectangle((520, 520, 858, 858), radius=104, fill=(10, 132, 255, 90))
glow = glow.filter(ImageFilter.GaussianBlur(60))
base.alpha_composite(glow)

# 4. 四象限 chambers
chamber_radius = 64
chambers = [
    ((28, 32, 40), (190, 190, 480, 480)),   # Q1 左上
    ((35, 43, 56), (544, 190, 834, 480)),   # Q2 右上
    ((35, 43, 56), (190, 544, 480, 834)),   # Q3 左下
    ("accent", (544, 544, 834, 834)),       # Q4 右下(高亮)
]
for color, box in chambers:
    if color == "accent":
        # 全尺寸渐变,仅高亮窗格区域有效
        cg_full = Image.new("RGB", (S, S), (0, 0, 0))
        cgd = ImageDraw.Draw(cg_full)
        for y in range(box[1], box[3]):
            t = (y - box[1]) / max(1, (box[3] - box[1] - 1))
            cgd.line([(box[0], y), (box[2], y)], fill=lerp((10, 132, 255), (0, 242, 254), t))
        cmask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(cmask).rounded_rectangle(box, radius=chamber_radius, fill=255)
        base.paste(cg_full, (0, 0), cmask)
    else:
        bd.rounded_rectangle(box, radius=chamber_radius, fill=color)

# 5. Q 尾巴(右下 45°,从四象限右下角延伸到背景,形成字母 Q)
tail = Image.new("RGBA", (S, S), (0, 0, 0, 0))
td = ImageDraw.Draw(tail)
td.line([(832, 832), (930, 930)], fill=(10, 132, 255, 240), width=46)
td.line([(872, 872), (930, 930)], fill=(0, 242, 254, 210), width=46)
td.ellipse([930 - 23, 930 - 23, 930 + 23, 930 + 23], fill=(0, 242, 254, 220))
td.ellipse([832 - 23, 832 - 23, 832 + 23, 832 + 23], fill=(10, 132, 255, 240))
base.alpha_composite(tail)

# 6. 输出各尺寸
out_dir = "Quadro.iconset"
os.makedirs(out_dir, exist_ok=True)
sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
for name, size in sizes.items():
    img = base.resize((size, size), Image.LANCZOS)
    img.save(os.path.join(out_dir, name))

base.resize((512, 512), Image.LANCZOS).save("icon-preview.png")
print("生成完成:", ", ".join(sorted(sizes.keys())))
print("预览: icon-preview.png")
