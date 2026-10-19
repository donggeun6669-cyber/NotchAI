#!/bin/zsh
# Build NotchDesk (calendar, recorder with on-device transcription, desk, launcher) and zip it
# with its guide, ready to hand to a buyer.
#   scripts/package-notchdesk.sh      → dist/NotchDesk.zip
#
# Signed ad hoc, like 강의녹음: the Apple Development certificate would put the owner's Apple ID
# e-mail into the signature, and without notarization (paid Developer ID) the buyer allows it once
# in System Settings either way. Source paths are remapped so the binary carries no home folder.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-whisper.sh
xcodegen generate --quiet
xcodebuild -project NotchAI.xcodeproj -scheme NotchDesk -configuration Release \
  -derivedDataPath build build -quiet CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=. -file-prefix-map $HOME=~"

stage=dist/NotchDesk
app="$stage/NotchDesk.app"
rm -rf "$stage" dist/NotchDesk.zip && mkdir -p "$stage"
ditto build/Build/Products/Release/NotchDesk.app "$app"
res="$app/Contents/Resources"
# Debug symbols carry the build folder's absolute paths; the buyer has no use for them.
strip -S -x "$app/Contents/MacOS/NotchDesk"
[[ -x "$res/whisper-cli" ]] || { echo "error: whisper-cli missing" >&2; exit 1; }
[[ -f "$res/ggml-large-v3-turbo-q5_0.bin" ]] || { echo "error: the transcription model is not in the app" >&2; exit 1; }
[[ -d "$res/MediaRemoteAdapter/MediaRemoteAdapter.framework" ]] || { echo "error: Now Playing helper missing" >&2; exit 1; }
strip -S -x "$res/whisper-cli"
# Stripping breaks a signature, and --deep does not reach executables under Resources: sign the
# helpers themselves first, or macOS kills them on launch.
codesign --force --sign - "$res/whisper-cli"
codesign --force --sign - "$res/MediaRemoteAdapter/MediaRemoteAdapterTestClient"
codesign --force --sign - "$res/MediaRemoteAdapter/MediaRemoteAdapter.framework"
codesign --force --deep --sign - "$app"
codesign --verify --strict "$app"
codesign --verify --strict "$res/whisper-cli"
"$res/whisper-cli" --help >/dev/null 2>&1 || { echo "error: the bundled whisper-cli does not run" >&2; exit 1; }
if grep -r -a -q "$HOME" "$app"; then
  grep -r -a -l "$HOME" "$app" >&2
  echo "error: the app still contains $HOME" >&2
  exit 1
fi
cp NotchDesk/Distribution/사용법.txt "$stage/"
ditto -c -k --sequesterRsrc --keepParent "$stage" dist/NotchDesk.zip
echo "Packaged: dist/NotchDesk.zip ($(du -h dist/NotchDesk.zip | cut -f1))"
