#!/bin/zsh
# Builds Dwn.app for macOS: the SwiftUI app plus the PyInstaller-packaged engine.
#   ./build.sh             build into ./dist/Dwn.app
#   ./build.sh --install   also copy to ~/Applications
#   ./build.sh --release   also write dist/Dwn-mac.zip and dist/Dwn-mac.zip.sha256
#
# Tools: ffmpeg and deno are taken from $DWN_TOOLS (a folder) when set, and
# bundled into the app so it runs on any Mac. Without it, the engine falls back
# to Homebrew's copies at runtime.
set -euo pipefail
ROOT=${0:A:h}
DIST=$ROOT/dist
APP=$DIST/Dwn.app
VERSION=$(tr -d '[:space:]' < $ROOT/VERSION)

echo "==> Engine ($VERSION)"
cd $ROOT/engine
[[ -d .venv ]] || { uv venv -q --python 3.12 .venv && uv pip install -q --python .venv/bin/python -r requirements.txt; }
.venv/bin/pyinstaller --noconfirm --clean --log-level WARN --onedir --name dwn-engine \
  --collect-all yt_dlp --collect-all yt_dlp_ejs --collect-submodules mutagen \
  --distpath $ROOT/engine/build/dist --workpath $ROOT/engine/build/work --specpath $ROOT/engine/build \
  engine.py
if [[ -n "${DWN_TOOLS:-}" ]]; then
  mkdir -p $ROOT/engine/build/dist/dwn-engine/bin
  cp $DWN_TOOLS/* $ROOT/engine/build/dist/dwn-engine/bin/
  chmod +x $ROOT/engine/build/dist/dwn-engine/bin/*
fi

echo "==> App"
cd $ROOT/app
swift build -c release

echo "==> Bundle"
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Dwn $APP/Contents/MacOS/Dwn
cp -R $ROOT/engine/build/dist/dwn-engine $APP/Contents/Resources/engine
cp $ROOT/app/Info.plist $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" $APP/Contents/Info.plist
[[ -f $ROOT/app/AppIcon.icns ]] && cp $ROOT/app/AppIcon.icns $APP/Contents/Resources/
# Release builds sign with a stable certificate ($DWN_SIGN_IDENTITY, a SHA-1 or
# name) so macOS keeps privacy permissions like Full Disk Access across
# updates. Local builds fall back to an ad-hoc signature.
SIGN_ARGS=(--force --deep --sign "${DWN_SIGN_IDENTITY:--}")
[[ -n "${DWN_SIGN_KEYCHAIN:-}" ]] && SIGN_ARGS+=(--keychain "$DWN_SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" $APP
codesign --verify --deep $APP
echo "Built $APP"

for arg in "$@"; do
  case $arg in
    --install)
      rm -rf ~/Applications/Dwn.app
      cp -R $APP ~/Applications/Dwn.app
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Dwn.app
      echo "Installed ~/Applications/Dwn.app" ;;
    --release)
      rm -f $DIST/Dwn-mac.zip $DIST/Dwn-mac.zip.sha256
      (cd $DIST && ditto -c -k --keepParent --sequesterRsrc Dwn.app Dwn-mac.zip)
      (cd $DIST && shasum -a 256 Dwn-mac.zip | awk '{print $1}' > Dwn-mac.zip.sha256)
      echo "Wrote $DIST/Dwn-mac.zip" ;;
  esac
done
