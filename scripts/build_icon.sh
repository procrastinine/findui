#!/bin/zsh
# The checked-in ICNS keeps normal app builds independent of a rasterizer.
# Only editing the SVG requires librsvg (brew install librsvg).
set -euo pipefail
root="${0:A:h:h}"
command -v rsvg-convert >/dev/null || { echo 'Install librsvg to regenerate the icon.' >&2; exit 1; }
mkdir -p "$root/.cache/icons"
staging="$(mktemp -d "$root/.cache/icons/build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/FindUI.iconset"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=''
    (( scale == 1 )) || suffix='@2x'
    pixels=$((size * scale))
    rsvg-convert --width "$pixels" --height "$pixels" "$root/packaging/FindUI.svg" \
      --output "$staging/FindUI.iconset/icon_${size}x${size}${suffix}.png"
  done
done
iconutil --convert icns --output "$staging/FindUI.icns" "$staging/FindUI.iconset"
mv "$staging/FindUI.icns" "$root/packaging/FindUI.icns"
echo 'Updated packaging/FindUI.icns from packaging/FindUI.svg'
