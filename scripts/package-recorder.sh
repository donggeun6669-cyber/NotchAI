#!/bin/zsh
# Build 강의녹음 (the recorder alone, with on-device transcription) and zip it with its guide,
# ready to hand to a friend.
#   scripts/package-recorder.sh      → dist/강의녹음.zip
#
# Signed ad hoc on purpose: the Apple Development certificate would put the owner's Apple ID
# e-mail into the app's signature. Without notarization (paid Developer ID) the friend has to
# allow it once in System Settings either way; the guide explains how. Source paths are remapped
# too, so the binary does not carry this Mac's home folder name.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-whisper.sh
xcodegen generate --quiet
xcodebuild -project NotchAI.xcodeproj -scheme LectureRecorder -configuration Release \
  -derivedDataPath build build -quiet CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=. -file-prefix-map $HOME=~"

stage=dist/강의녹음
rm -rf dist && mkdir -p "$stage"
ditto build/Build/Products/Release/LectureRecorder.app "$stage/강의녹음.app"
# Debug symbols carry the build folder's absolute paths; the friend has no use for them.
strip -S -x "$stage/강의녹음.app/Contents/MacOS/LectureRecorder"
[[ -x "$stage/강의녹음.app/Contents/Resources/whisper-cli" ]] || { echo "error: whisper-cli missing" >&2; exit 1; }
strip -S -x "$stage/강의녹음.app/Contents/Resources/whisper-cli"
[[ -f "$stage/강의녹음.app/Contents/Resources/ggml-large-v3-turbo-q5_0.bin" ]] || {
  echo "error: the transcription model is not in the app" >&2; exit 1; }
# Stripping breaks a signature, and --deep does not reach executables under Resources: sign the
# helper itself first, or macOS kills it on launch (exit 137).
codesign --force --sign - "$stage/강의녹음.app/Contents/Resources/whisper-cli"
codesign --force --deep --sign - "$stage/강의녹음.app"
codesign --verify --strict "$stage/강의녹음.app"
codesign --verify --strict "$stage/강의녹음.app/Contents/Resources/whisper-cli"
"$stage/강의녹음.app/Contents/Resources/whisper-cli" --help >/dev/null 2>&1 || {
  echo "error: the bundled whisper-cli does not run" >&2; exit 1; }
if grep -r -a -q "$HOME" "$stage/강의녹음.app"; then
  echo "error: the app still contains $HOME" >&2
  exit 1
fi
cp LectureRecorder/Distribution/사용법.txt "$stage/"
ditto -c -k --sequesterRsrc --keepParent "$stage" dist/강의녹음.zip
echo "Packaged: dist/강의녹음.zip ($(du -h dist/강의녹음.zip | cut -f1))"
