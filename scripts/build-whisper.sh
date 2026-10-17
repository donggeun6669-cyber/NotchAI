#!/bin/zsh
# Build a self-contained whisper-cli (whisper.cpp, MIT) for 강의녹음's transcription.
#   scripts/build-whisper.sh        → build/whisper/whisper-cli (universal: arm64 + x86_64)
#                                     build/whisper/models/ggml-large-v3-turbo-q5_0.bin
#
# The model is quantized here from the full large-v3-turbo, whose SHA-256 is checked first — the
# same file DEAN's transcribe.sh and the app's download use. 5-bit is a third of the size; on
# 2026-10-18 it was compared with the full model on real lectures before being shipped.
# Static libraries and the Metal shaders embedded in the binary, so the app runs it without
# Homebrew. Pinned to the version the DEAN transcribe.sh uses on this Mac (v1.9.4).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
VERSION=v1.9.4
ROOT=build/whisper
SRC=$ROOT/src
OUT=$ROOT/whisper-cli

FULL_MODEL=${WHISPER_FULL_MODEL:-$HOME/Documents/Lecture-Recordings/models/ggml-large-v3-turbo.bin}
FULL_SHA=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
MODEL=$ROOT/models/ggml-large-v3-turbo-q5_0.bin

make_model() {
  [[ -f $MODEL ]] && return
  [[ -f $FULL_MODEL ]] || { echo "error: full model not found: $FULL_MODEL (set WHISPER_FULL_MODEL)" >&2; exit 1; }
  [[ "$(shasum -a 256 "$FULL_MODEL" | cut -d' ' -f1)" == "$FULL_SHA" ]] || {
    echo "error: $FULL_MODEL is not the published large-v3-turbo" >&2; exit 1; }
  cmake --build $ROOT/arm64 --target whisper-quantize -j 8 >/dev/null
  mkdir -p $ROOT/models
  $ROOT/arm64/bin/whisper-quantize "$FULL_MODEL" $MODEL.partial q5_0 >/dev/null
  mv $MODEL.partial $MODEL
  echo "quantized $MODEL ($(du -h $MODEL | cut -f1))"
}

STAMP="$VERSION $(shasum -a 256 "$0" | cut -c1-12)"
if [[ -x $OUT && -f $ROOT/.version && "$(cat $ROOT/.version)" == "$STAMP" ]]; then
  echo "whisper-cli $VERSION already built: $OUT"
  make_model
  exit 0
fi
rm -rf $ROOT/arm64 $ROOT/x86_64   # a clean configure, so changed flags always take effect
[[ -d $SRC ]] || git clone --depth 1 --branch $VERSION https://github.com/ggml-org/whisper.cpp.git $SRC

common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
        -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON
        -DGGML_NATIVE=OFF -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_OPENMP=OFF
        # Keep this Mac's folder names out of the binary (assert messages embed source paths).
        "-DCMAKE_C_FLAGS=-ffile-prefix-map=$PWD=. -ffile-prefix-map=$HOME=~"
        "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$PWD=. -ffile-prefix-map=$HOME=~"
        "-DCMAKE_OBJC_FLAGS=-ffile-prefix-map=$PWD=. -ffile-prefix-map=$HOME=~")
# Apple silicon: GPU through Metal, shaders compiled into the binary.
cmake -S $SRC -B $ROOT/arm64 "${common[@]}" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null
cmake --build $ROOT/arm64 --target whisper-cli -j 8 >/dev/null
# Intel: CPU only. Every Intel Mac that runs macOS 15 has AVX2/FMA/F16C.
cmake -S $SRC -B $ROOT/x86_64 "${common[@]}" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DGGML_METAL=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON >/dev/null
cmake --build $ROOT/x86_64 --target whisper-cli -j 8 >/dev/null

lipo -create $ROOT/arm64/bin/whisper-cli $ROOT/x86_64/bin/whisper-cli -output $OUT
cp $SRC/LICENSE $ROOT/whisper-LICENSE
echo "$STAMP" > $ROOT/.version
make_model
echo "built $OUT ($(lipo -archs $OUT), $(du -h $OUT | cut -f1))"
