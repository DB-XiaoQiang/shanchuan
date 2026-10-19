#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

MASTER="$PWD/Resources/AppIcon.png"
ICON="$PWD/Resources/AppIcon.icns"
if [[ ! -f "$MASTER" ]]; then
    print -u2 "缺少图标原图：$MASTER；请提供至少 1024 × 1024 像素的正方形 PNG。"
    exit 1
fi

IMAGE_INFO="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$MASTER")"
IMAGE_FORMAT="$(print -r -- "$IMAGE_INFO" | /usr/bin/awk '$1 == "format:" {print $2}')"
IMAGE_WIDTH="$(print -r -- "$IMAGE_INFO" | /usr/bin/awk '$1 == "pixelWidth:" {print $2}')"
IMAGE_HEIGHT="$(print -r -- "$IMAGE_INFO" | /usr/bin/awk '$1 == "pixelHeight:" {print $2}')"
if [[ "$IMAGE_FORMAT" != 'png' || "$IMAGE_WIDTH" != <-> || "$IMAGE_HEIGHT" != <-> ]]; then
    print -u2 '图标原图必须是可读取的 PNG 文件。'
    exit 1
fi
if (( IMAGE_WIDTH != IMAGE_HEIGHT || IMAGE_WIDTH < 1024 )); then
    print -u2 "图标原图必须是至少 1024 × 1024 像素的正方形；当前为 ${IMAGE_WIDTH} × ${IMAGE_HEIGHT}。"
    exit 1
fi

ICON_WORK="$(/usr/bin/mktemp -d "$PWD/Resources/.app-icon.XXXXXX")"
trap '/bin/rm -rf -- "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/AppIcon.iconset"
/bin/mkdir -p "$ICONSET"

for ICON_SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$MASTER" \
        --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_RETINA_SIZE=$(( ICON_SIZE * 2 ))
    /usr/bin/sips -z "$ICON_RETINA_SIZE" "$ICON_RETINA_SIZE" "$MASTER" \
        --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICON_WORK/AppIcon.icns"
/bin/mv -f -- "$ICON_WORK/AppIcon.icns" "$ICON"
print -r -- "$ICON"
