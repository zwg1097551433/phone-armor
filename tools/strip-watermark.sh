#!/bin/sh
# strip-watermark.sh — 裁掉图片底部区域（第三方生图接口的水印通常压在那里）
#
#   sh strip-watermark.sh in.jpg              生成 in.nowm.jpg（默认裁底部 8%）
#   sh strip-watermark.sh in.jpg out.jpg      指定输出
#   sh strip-watermark.sh in.jpg out.jpg 12   裁掉底部 12%
#
# 自动挑可用后端：ffmpeg → ImageMagick(convert/magick) → python3 + Pillow
# 三个都没有就明确报错，并给出安装命令。
set -u

IN="${1:-}"
OUT="${2:-}"
PCT="${3:-8}"

if [ -z "$IN" ] || [ ! -f "$IN" ]; then
  printf '用法：sh strip-watermark.sh <输入图> [输出图] [底部百分比，默认8]\n' >&2
  exit 1
fi
[ -n "$OUT" ] || OUT="${IN%.*}.nowm.${IN##*.}"

# 保留比例 = 100 - PCT
KEEP=$((100 - PCT))
# ffmpeg 用小数比例
FRAC=$(awk -v k="$KEEP" 'BEGIN{printf "%.4f", k/100}' 2>/dev/null || echo "0.92")

ok=0

# ---- 1. ffmpeg ----
if command -v ffmpeg >/dev/null 2>&1; then
  if ffmpeg -y -loglevel error -i "$IN" -vf "crop=iw:ih*${FRAC}:0:0" "$OUT" 2>/dev/null; then
    ok=1; BACKEND="ffmpeg"
  fi
fi

# ---- 2. ImageMagick ----
if [ "$ok" = 0 ]; then
  for c in convert magick; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" "$IN" -gravity north -crop "100%x${KEEP}%+0+0" +repage "$OUT" 2>/dev/null; then
      ok=1; BACKEND="$c"
    fi
    [ "$ok" = 1 ] && break
  done
fi

# ---- 3. python3 + Pillow ----
if [ "$ok" = 0 ] && command -v python3 >/dev/null 2>&1; then
  if python3 - "$IN" "$OUT" "$PCT" <<'PY' 2>/dev/null
import sys
from PIL import Image
src, dst, pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
im = Image.open(src)
w, h = im.size
im.crop((0, 0, w, int(h * (100 - pct) / 100))).save(dst, quality=95)
PY
  then
    ok=1; BACKEND="python3+Pillow"
  fi
fi

if [ "$ok" = 0 ]; then
  # 三个后端都没有，尝试装最轻的 python3-pil（约 5 MB）
  printf '没有可用的图像后端，尝试自动安装 python3-pil ...\n'
  if command -v apt-get >/dev/null 2>&1; then
    ( apt-get update -qq && apt-get install -y -qq python3-pil ) >/dev/null 2>&1
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' 2>/dev/null; then
      python3 - "$IN" "$OUT" "$PCT" <<'PY' && ok=1
import sys
from PIL import Image
src, dst, pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
im = Image.open(src)
w, h = im.size
im.crop((0, 0, w, int(h * (100 - pct) / 100))).save(dst, quality=95)
PY
      BACKEND="python3+Pillow(新装)"
    fi
  fi
fi

if [ "$ok" = 0 ]; then
  printf '\033[1;31m没有可用的图像处理后端\033[0m\n' >&2
  printf '手动装一个（PRoot Ubuntu）：\n' >&2
  printf '  apt update && apt install -y python3-pil   # 约 5 MB，最小\n' >&2
  printf '  apt update && apt install -y imagemagick   # 约 30 MB\n' >&2
  printf '  apt update && apt install -y ffmpeg        # 约 60 MB\n' >&2
  exit 1
fi

printf '已裁掉底部 %s%% → %s（用 %s）\n' "$PCT" "$OUT" "$BACKEND"
printf '原图保留：%s\n' "$IN"
