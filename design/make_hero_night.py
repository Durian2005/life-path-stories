"""由 app/assets/hero.jpg 生成逐像素对齐的夜色版 app/assets/hero-night.jpg。

用途：深色模式与浅色模式必须是「同一幅画」，切换时只改变天空里的
月亮 / 星星和整体色调，山脉、人物、道路、白花、树的位置与大小不动。

V2（11-06，按用户给的参考图重做色调）：
参考图是一幅「透亮的夜」——深靛蓝夜空、月光下的青绿山坡、
画面里最亮的是那条发白的小路和白花、橙色背包依然醒目。
旧版整体乘一个暗灰系数，结果又灰又闷，被打回。V2 改成分区映射：
  ① 擦掉原图右上角那颗橙色太阳（月亮由 CSS 叠加层绘制）；
  ② 逐通道乘「随高度变化的色调系数」：顶部深靛蓝 → 地面月光青绿，
     系数整体比 V1 亮一档，保住夜里的通透感；
  ③ 高亮度低饱和的像素（路面 / 白花）往「月光白」提亮，
     越靠地面越按此处理（天空的云不参与，避免把夜空洗白）；
  ④ 橙色背包等强暖色像素混回一份原色，夜里依然醒目；
  ⑤ 收尾：轻微提饱和 + 中调 gamma 提亮 + 右上天空一层月光环境光。

依赖：numpy、Pillow。用法（在项目根目录执行）：
    python design/make_hero_night.py

注意：脚本会覆盖 app/assets/hero-night.jpg；重新生成后记得升全站版本号，
否则观众会吃到浏览器缓存里的旧图。
"""
import pathlib

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / 'app/assets/hero.jpg'
DST = ROOT / 'app/assets/hero-night.jpg'

im = Image.open(SRC).convert('RGB')
rgb = np.asarray(im).astype(np.float32) / 255.0
H, W, _ = rgb.shape
Y, X = np.mgrid[0:H, 0:W]
print('source:', im.size)

# ---------- ① 定位并擦掉橙色太阳 ----------
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
region = (Y < H * 0.30) & (X > W * 0.70)
sun = region & (r > 0.70) & (g > 0.22) & (g < 0.70) & (b < 0.48) & ((r - g) > 0.25)
pts = np.argwhere(sun)
print('sun pixels:', len(pts))
if len(pts) > 50:
    cy, cx = pts.mean(axis=0)
    rad = max(np.ptp(pts[:, 0]) / 2, np.ptp(pts[:, 1]) / 2) * 1.30
    print('sun center: (%.0f, %.0f) radius %.1f' % (cx, cy, rad))
    d = np.sqrt((X - cx) ** 2 + (Y - cy) ** 2)
    ring = (d > rad * 1.3) & (d < rad * 2.4)
    sky = rgb[ring].mean(axis=0)
    alpha = np.clip((rad * 1.25 - d) / (rad * 0.45), 0, 1)[..., None]
    rgb = rgb * (1 - alpha) + sky * alpha   # 软边替换，避免留下圆斑
else:
    raise RuntimeError('没找到橙色太阳，请检查阈值，不要直接覆盖夜色图')

r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
L = rgb @ np.array([0.299, 0.587, 0.114], dtype=np.float32)

# 高亮度 + 低饱和 → 路面、白花、白衬衫（天空的云也满足，但后面用高度门控排除）
sat = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)
bright_neutral = np.clip((L - 0.60) / 0.28, 0, 1) * (1 - np.clip(sat * 2.4, 0, 1))
# 暖中性门控：小路是暖奶油色（r 明显大于 b），湖面雾带是冷色（b ≥ r）。
# 只提亮真正偏暖的高亮像素，否则湖面会被洗成一片白（参考图里湖水接近
# 深蓝，是夜里最沉的元素之一）——V2 第一稿就栽在这上面。
warm_neutral = np.clip(((r - b) - 0.015) / 0.05, 0, 1)
bright_neutral = bright_neutral * warm_neutral

# 强暖色 → 橙色背包、皮肤（夜里要保住这份橙）
warm = np.clip((r - np.maximum(g, b) * 0.92) * 2.4, 0, 1)

# 高度因子：0=天顶 1=画面底部
t = np.clip((Y / (H * 0.66))[:, :, None], 0, 1) ** 0.9
# 地面门控：t > 0.42 之后才允许「提亮成月光白 / 混回暖色」，
# 云都集中在 t < 0.45 的天空里，不会被洗白
gate = np.clip((t[..., 0] - 0.42) / 0.25, 0, 1)

# ---------- ② 分区夜色映射 ----------
# 顶部深靛蓝（参考图夜空 ≈ #1e2d5a 一带）→ 地面月光青绿（比 V1 亮一整档）
sky_tint = np.array([0.140, 0.190, 0.430], dtype=np.float32)
ground_tint = np.array([0.560, 0.700, 0.740], dtype=np.float32)
out = rgb * (sky_tint + t * (ground_tint - sky_tint))

# ---------- ②½ 冷色高亮区（湖面 / 雾带）压成夜湖蓝 ----------
# 参考图里这片是偏深的蓝（湖面反夜空）。用乘法而不是混向目标色：
# 相对明暗保留，雾里的远山剪影不会糊掉。
cool_pale = (b >= r) * np.clip((L - 0.55) / 0.3, 0, 1) * np.clip((t[..., 0] - 0.28) / 0.2, 0, 1)
out = out * (1 - cool_pale[..., None] * np.array([0.28, 0.16, -0.10], dtype=np.float32))

# ---------- ③ 路面 / 白花的月光提亮 ----------
# 参考图里小路是画面最亮的元素之一，白花像撒了光点。
# 往同一个「月光白」混合，混合强度跟 bright_neutral 与地面门控走。
path_target = np.array([0.885, 0.875, 0.845], dtype=np.float32)
lift = (bright_neutral * gate * 0.92)[..., None]
out = out * (1 - lift) + path_target * lift

# ---------- ④ 暖色保护：橙色背包混回一份原色 ----------
keep = (warm * gate * 0.55)[..., None]
out = out * (1 - keep) + rgb * keep

# ---------- ⑤ 收尾 ----------
# 右上天空一层很淡的月光环境光（月亮本体由 CSS 画，这里只提氛围）
gx, gy = W * 0.86, H * 0.14
amb = np.clip(1 - np.sqrt(((X - gx) / (W * 0.50)) ** 2 +
                          ((Y - gy) / (H * 0.50)) ** 2), 0, 1) ** 2
out += amb[..., None] * np.array([0.035, 0.050, 0.090], dtype=np.float32)

# 顶部再压一档，夜空更沉
top = np.clip(1 - (Y / (H * 0.45))[:, :, None], 0, 1)
out = out * (1 - top * 0.18)

# 提饱和 + 中调 gamma 提亮：去灰气、保通透
gray = (out @ np.array([0.299, 0.587, 0.114], dtype=np.float32))[..., None]
out = gray + (out - gray) * 1.20
out = np.clip(out, 0, 1) ** (1.0 / 1.07)

Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), 'RGB').save(
    DST, quality=88, subsampling=0, optimize=True)
print('saved:', DST.name, DST.stat().st_size, 'bytes', Image.open(DST).size)

# ---------- ⑥ 结构一致性自检 ----------
a = np.asarray(im.convert('L')).astype(np.float32)
c = np.asarray(Image.open(DST).convert('L')).astype(np.float32)
corr = np.corrcoef(np.abs(np.diff(a, axis=1))[:, :-1].ravel(),
                   np.abs(np.diff(c, axis=1))[:, :-1].ravel())[0, 1]
print('edge-map correlation: %.4f  (>0.95 说明构图没动)' % corr)
