#!/bin/zsh
# Render an icon drawing script at 1024px and fill an .appiconset with every macOS size.
#   scripts/icon/make-appiconset.sh scripts/icon/draw-notchai-icon.swift NotchAI/Resources/Assets.xcassets/AppIcon.appiconset
set -euo pipefail
script=$1 out=$2
tmp=$(mktemp -d)
swiftc -O "$script" -o "$tmp/draw"
"$tmp/draw" "$tmp/1024.png" >/dev/null
mkdir -p "$out"
images=()
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    name="icon_${size}x${size}@${scale}x.png"
    sips -z $px $px "$tmp/1024.png" --out "$out/$name" >/dev/null
    images+=("{\"size\":\"${size}x${size}\",\"idiom\":\"mac\",\"filename\":\"$name\",\"scale\":\"${scale}x\"}")
  done
done
print -r -- "{\"images\":[${(j:,:)images}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$out/Contents.json"
print -r -- '{"info":{"version":1,"author":"xcode"}}' > "$(dirname "$out")/Contents.json"
rm -rf "$tmp"
echo "wrote $out"
