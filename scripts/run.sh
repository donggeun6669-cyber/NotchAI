#!/bin/zsh
# Build NotchAI and (re)launch it.
#   scripts/run.sh            build and launch from build/
#   scripts/run.sh install    build, copy to ~/Applications, launch from there
#   scripts/run.sh expanded   launch with the panel pinned open (screenshots / debugging)
#   scripts/run.sh test       run unit tests (needs Xcode with its license accepted)
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode needs its license accepted and its first-launch packages installed:
#   sudo xcodebuild -license accept
#   sudo xcodebuild -runFirstLaunch
# Until both are done, fall back to compiling with the Command Line Tools and assembling the
# app bundle by hand. `-showsdks` fails if either step is missing, so it is the readiness test.
# Sign with the "Apple Development" certificate when there is one. macOS ties permissions
# (Accessibility, controlling Chrome, clipboard) to the signature: with the throwaway ad-hoc
# signature every rebuild looked like a new app and those permissions had to be granted again.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
SIGN_ARGS=()
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY")
fi

# `xcodebuild -showsdks` still succeeds when the first-launch packages are missing, so the only
# reliable test is trying the build and falling back if it fails.
xcode_build() {
  [[ -d /Applications/Xcode.app ]] || return 1
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodegen generate --quiet &&
    xcodebuild -project NotchAI.xcodeproj -scheme NotchAI -configuration Release \
      -derivedDataPath build build -quiet "${SIGN_ARGS[@]}"
}

if [[ "${1:-}" == "test" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodegen generate --quiet
  xcodebuild -project NotchAI.xcodeproj -scheme NotchAI -destination 'platform=macOS' \
    -derivedDataPath build test -quiet || {
      echo
      echo "Tests failed. If Xcode has never been set up on this Mac, run once:"
      echo "  sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
      exit 1
    }
  exit 0
fi

if xcode_build 2>/dev/null; then
  APP=build/Build/Products/Release/NotchAI.app
else
  echo "Building with the Command Line Tools (Xcode not set up yet)."
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  APP=build/manual/NotchAI.app
  mkdir -p "$APP/Contents/MacOS"
  swiftc -swift-version 6 -target arm64-apple-macosx26.0 -parse-as-library -O \
    $(find NotchAI -name '*.swift') -o "$APP/Contents/MacOS/NotchAI"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NotchAI</string>
<key>CFBundleIdentifier</key><string>com.dongeun.NotchAI</string>
<key>CFBundleName</key><string>NotchAI</string>
<key>CFBundleDisplayName</key><string>NotchAI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>지금 재생 중인 음악과 크롬에서 보고 있는 페이지를 읽기 위해 사용합니다.</string>
<key>NSMicrophoneUsageDescription</key><string>강의실 등 주변 소리를 녹음하기 위해 사용합니다.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>노치 달력의 오늘 할 일을 미리 알림 「오늘 할 일」 목록에서 바로 읽습니다. 할 일은 이 맥 밖으로 나가지 않습니다.</string>
<key>NSRemindersUsageDescription</key><string>노치 달력의 오늘 할 일을 미리 알림 「오늘 할 일」 목록에서 바로 읽습니다. 할 일은 이 맥 밖으로 나가지 않습니다.</string>
</dict></plist>
PLIST
  codesign -s "${IDENTITY:--}" --force "$APP" >/dev/null
fi

pkill -x NotchAI 2>/dev/null || true
sleep 0.3

case "${1:-}" in
  install)
    mkdir -p ~/Applications
    rm -rf ~/Applications/NotchAI.app
    cp -R "$APP" ~/Applications/NotchAI.app
    open ~/Applications/NotchAI.app
    echo "Installed: ~/Applications/NotchAI.app ($(codesign -dvv ~/Applications/NotchAI.app 2>&1 | grep -m1 -E '^(Authority|Signature)=' ))"
    ;;
  expanded) open -n "$APP" --args -startExpanded YES ;;
  *) open -n "$APP" ;;
esac
