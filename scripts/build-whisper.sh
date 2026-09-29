#!/bin/zsh
# Build a self-contained whisper-cli (whisper.cpp, MIT) for 강의녹음's transcription.
#   scripts/build-whisper.sh        → build/whisper/whisper-cli (universal: arm64 + x86_64)
#
# Static libraries and the Metal shaders embedded in the binary, so the app runs it without
# Homebrew. Pinned to the version the DEAN transcribe.sh uses on this Mac (v1.9.4).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
VERSION=v1.9.4
ROOT=build/whisper
SRC=$ROOT/src
OUT=$ROOT/whisper-cli

STAMP="$VERSION $(shasum -a 256 "$0" | cut -c1-12)"
if [[ -x $OUT && -f $ROOT/.version && "$(cat $ROOT/.version)" == "$STAMP" ]]; then
  echo "whisper-cli $VERSION already built: $OUT"
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
echo "built $OUT ($(lipo -archs $OUT), $(du -h $OUT | cut -f1))"
