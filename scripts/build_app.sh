#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FindUI"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/findui-clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/findui-swiftpm-module-cache}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
bash "$ROOT_DIR/scripts/build_core.sh"
bash "$ROOT_DIR/scripts/build_search_tools.sh"

swift build --package-path "$ROOT_DIR" --disable-sandbox --disable-keychain --disable-netrc --cache-path "$ROOT_DIR/.cache/swiftpm" \
  --sdk "$MACOS_SDK_PATH" -c release \
  -Xswiftc -DFINDUI_DISTRIBUTION \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=/src/FindUI" \
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$MACOS_SDK_VERSION"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --disable-sandbox --disable-keychain --disable-netrc --cache-path "$ROOT_DIR/.cache/swiftpm" -c release --show-bin-path)"

# The SDK recorded in Mach-O controls compatibility appearance in AppKit/SwiftUI.
# SwiftPM can otherwise link with the deployment target as the SDK version.
for executable in FindUI FindUIApp; do
  LINKED_SDK_VERSION="$(xcrun vtool -show-build "$BIN_DIR/$executable" | awk '$1 == "sdk" { print $2; exit }')"
  if [[ "$LINKED_SDK_VERSION" != "$MACOS_SDK_VERSION" ]]; then
    echo "Expected SDK $MACOS_SDK_VERSION, but $executable records $LINKED_SDK_VERSION" >&2
    exit 1
  fi
done

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.build-app.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/FindUIApp" "$STAGED_APP/Contents/MacOS/FindUIApp"
# Swift's AST/debug records can still reference local module caches even with
# prefix mapping. Keep them in the build tree, outside the distributed app.
xcrun strip -S "$STAGED_APP/Contents/MacOS/FindUI" "$STAGED_APP/Contents/MacOS/FindUIApp"
cp "$ROOT_DIR/.build/content-worker/release/findui-content" "$STAGED_APP/Contents/MacOS/findui-content"
for tool in fd rg fzf; do cp "$ROOT_DIR/.build/search-tools/bin/$tool" "$STAGED_APP/Contents/MacOS/$tool"; done
cp "$ROOT_DIR/packaging/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT_DIR/packaging/FindUI.icns" "$STAGED_APP/Contents/Resources/FindUI.icns"
cp -R "$ROOT_DIR/.build/content-worker/licenses" "$STAGED_APP/Contents/Resources/Licenses"
cp -R "$ROOT_DIR/.build/search-tools/licenses" "$STAGED_APP/Contents/Resources/Licenses/SearchTools"
cp "$ROOT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/Licenses/FindUI-LICENSE.txt"
cp "$ROOT_DIR/docs/licenses/linguist-LICENSE.txt" "$STAGED_APP/Contents/Resources/Licenses/linguist-LICENSE.txt"
ruby "$ROOT_DIR/scripts/build_info.rb" "$ROOT_DIR" "$MACOS_SDK_VERSION" > "$STAGED_APP/Contents/Resources/BuildInfo.json"
plutil -insert DTSDKName -string "macosx$MACOS_SDK_VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$STAGED_APP/Contents/Info.plist"

# Ad-hoc signing works locally without an Apple Developer account or certificate.
codesign --force --sign - "$STAGED_APP/Contents/MacOS/findui-content"
codesign --force --sign - "$STAGED_APP/Contents/MacOS/FindUI"
for tool in fd rg fzf; do codesign --force --sign - "$STAGED_APP/Contents/MacOS/$tool"; done
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"

if [[ -e "$APP_DIR" ]]; then
  mv "$APP_DIR" "$STAGING_DIR/previous.app"
fi
mv "$STAGED_APP" "$APP_DIR"
echo "$APP_DIR"
