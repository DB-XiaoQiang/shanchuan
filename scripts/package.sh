#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
SIGNING_IDENTITY="${COPYTOOL_SIGNING_IDENTITY:-}"
UNSIGNED_CI="${SHANCHUAN_UNSIGNED_CI:-0}"
VERSION="$(cat VERSION)"
BUILD_NUMBER="${SHANCHUAN_BUILD_NUMBER:-1}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || "$BUILD_NUMBER" != <-> ]]; then
    print -u2 'VERSION 必须为三段版本号，构建号必须为整数。'
    exit 1
fi
if [[ "$UNSIGNED_CI" == 1 && "${CI:-}" != true ]]; then
    print -u2 '无签名打包仅用于 CI 编译产物。'
    exit 1
fi
if [[ "$UNSIGNED_CI" != 1 && -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITIES=( ${(f)"$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')"} )
    if (( ${#SIGNING_IDENTITIES} != 1 )); then
        print -u2 '请通过 COPYTOOL_SIGNING_IDENTITY 指定有效签名身份；需要稳定身份以保留辅助功能与钥匙串授权。'
        exit 1
    fi
    SIGNING_IDENTITY="$SIGNING_IDENTITIES[1]"
fi
if [[ "$SIGNING_IDENTITY" == '-' ]]; then
    print -u2 '全局快捷键版本需要稳定签名身份，不使用每次构建都会变化的 ad hoc 签名。'
    exit 1
fi
./scripts/build-icons.sh
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
DIST="$PWD/dist"
FINAL_APP="$DIST/闪传.app"
FINAL_ZIP="$DIST/闪传-macos-arm64.zip"
if [[ -L "$DIST" || -L "$FINAL_APP" || -L "$FINAL_ZIP" ]]; then
    print -u2 '打包输出路径不能是符号链接；为避免覆盖其他位置，已停止。'
    exit 1
fi
if [[ -e "$FINAL_APP" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINAL_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != 'local.copytool.independent' ]]; then
        print -u2 "已有同名应用的 Bundle ID 不匹配，已保留：$FINAL_APP"
        exit 1
    fi
fi
/bin/mkdir -p "$DIST"
PACKAGE_WORK="$(/usr/bin/mktemp -d "$DIST/.shanchuan-build.XXXXXX")"
cleanup_package() {
    # 替换中断时恢复原输出；成功后仅清理本次临时文件。
    if [[ ! -e "$FINAL_APP" && -e "$PACKAGE_WORK/previous.app" ]]; then
        /bin/mv -- "$PACKAGE_WORK/previous.app" "$FINAL_APP"
    fi
    /bin/rm -rf -- "$PACKAGE_WORK"
}
trap cleanup_package EXIT
APP="$PACKAGE_WORK/闪传.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$BIN_DIR/CopyTool" "$APP/Contents/MacOS/CopyTool"
/bin/cp Resources/AppIcon.icns Resources/AppIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.copytool.independent</string>
<key>CFBundleExecutable</key><string>CopyTool</string>
<key>CFBundleName</key><string>闪传</string>
<key>CFBundleDisplayName</key><string>闪传</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
<key>CFBundleVersion</key><string>BUILD_PLACEHOLDER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Independent implementation, 2026</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/bin/mkdir -p "$APP/Contents/Frameworks"
FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
    FRAMEWORK="$(/usr/bin/find .build/artifacts -path '*/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit)"
fi
[[ -d "$FRAMEWORK" ]] || { print -u2 '缺少 Sparkle.framework'; exit 1; }
/usr/bin/ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's nested services keep their upstream signatures; sign the enclosing app.
if [[ -n "${SHANCHUAN_UPDATE_FEED:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SHANCHUAN_UPDATE_FEED" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$APP/Contents/Info.plist"
fi
if [[ "$UNSIGNED_CI" != 1 ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
    codesign --verify --deep --strict "$APP"
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        /usr/bin/ditto -c -k --keepParent "$APP" "$PACKAGE_WORK/notarize.zip"
        xcrun notarytool submit "$PACKAGE_WORK/notarize.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
    fi
fi
/usr/bin/ditto -c -k --keepParent "$APP" "$PACKAGE_WORK/闪传-macos-arm64.zip"
if [[ -e "$FINAL_APP" ]]; then
    /bin/mv -- "$FINAL_APP" "$PACKAGE_WORK/previous.app"
fi
/bin/mv -- "$APP" "$FINAL_APP"
/bin/mv -f -- "$PACKAGE_WORK/闪传-macos-arm64.zip" "$FINAL_ZIP"
print -r -- "$FINAL_APP"
