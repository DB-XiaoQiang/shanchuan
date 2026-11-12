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
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
DIST="$PWD/dist"
FINAL_APP="$DIST/闪传.app"
FINAL_ZIP="$DIST/Shanchuan-macos-arm64.zip"
FINAL_DMG="$DIST/Shanchuan-macos-arm64.dmg"
if [[ -L "$DIST" || -L "$FINAL_APP" || -L "$FINAL_ZIP" || -L "$FINAL_DMG" ]]; then
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
OUTPUT_NAMES=("闪传.app" "Shanchuan-macos-arm64.zip" "Shanchuan-macos-arm64.dmg")
PUBLISH_STARTED=0
PUBLISH_DONE=0
cleanup_package() {
    local result=$?
    local restore_failed=0
    local output_name
    # 失败时恢复整批输出；回滚失败则保留备份目录以便人工恢复。
    if (( PUBLISH_STARTED && ! PUBLISH_DONE )); then
        for output_name in "${OUTPUT_NAMES[@]}"; do
            if [[ -e "$PACKAGE_WORK/previous/$output_name" ]]; then
                /bin/rm -rf -- "$DIST/$output_name"
                /bin/mv -- "$PACKAGE_WORK/previous/$output_name" "$DIST/$output_name" || restore_failed=1
            elif [[ ! -e "$PACKAGE_WORK/$output_name" ]]; then
                /bin/rm -rf -- "$DIST/$output_name"
            fi
        done
    fi
    if (( restore_failed )); then
        print -u2 "输出回滚未完成，已保留备份：$PACKAGE_WORK"
        return 1
    fi
    /bin/rm -rf -- "$PACKAGE_WORK"
    return $result
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
if [[ -n "${SHANCHUAN_UPDATE_FEED:-}" || -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    [[ -n "${SHANCHUAN_UPDATE_FEED:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" && "$SHANCHUAN_UPDATE_FEED" == https://* ]] || {
        print -u2 '自动更新需同时提供 HTTPS 更新源和 Sparkle 公钥。'; exit 1
    }
fi
if [[ -n "${SHANCHUAN_UPDATE_FEED:-}" && -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SHANCHUAN_UPDATE_FEED" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$APP/Contents/Info.plist"
fi
if [[ "$UNSIGNED_CI" != 1 ]]; then
    # Re-sign nested code from the inside out, preserving Sparkle entitlements.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for NESTED in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
        [[ -e "$NESTED" ]] || { print -u2 "Sparkle 签名目标缺失：$NESTED"; exit 1; }
        codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=identifier,entitlements --options runtime --timestamp "$NESTED"
    done
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
    codesign --verify --deep --strict "$APP"
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        /usr/bin/ditto -c -k --keepParent "$APP" "$PACKAGE_WORK/notarize.zip"
        NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then
            NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN_PATH")
        fi
        xcrun notarytool submit "$PACKAGE_WORK/notarize.zip" "${NOTARY_ARGS[@]}" --wait
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
    fi
fi
/usr/bin/ditto -c -k --keepParent "$APP" "$PACKAGE_WORK/Shanchuan-macos-arm64.zip"

# DMG 用于拖拽安装，ZIP 继续作为 Sparkle 更新包。
DMG_ROOT="$PACKAGE_WORK/dmg-root"
DMG_IMAGE="$PACKAGE_WORK/Shanchuan-macos-arm64.dmg"
/bin/mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP" "$DMG_ROOT/闪传.app"
/bin/ln -s /Applications "$DMG_ROOT/Applications"
cat > "$DMG_ROOT/安装说明.txt" <<'INSTALL'
闪传安装说明

1. 将“闪传.app”拖到旁边的 Applications（应用程序）文件夹。
2. 复制完成后推出此磁盘映像。
3. 从“应用程序”打开闪传，并按提示授予快捷键所需的辅助功能权限。

升级前请等待传输完成，并从闪传菜单选择“退出”，再替换应用。
INSTALL
/usr/bin/hdiutil create -volname "闪传 $VERSION" -srcfolder "$DMG_ROOT" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_IMAGE"
VERIFY_ARGS=()
if [[ "$UNSIGNED_CI" != 1 ]]; then
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_IMAGE"
    codesign --verify --strict "$DMG_IMAGE"
    VERIFY_ARGS+=(--signed)
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG_IMAGE" "${NOTARY_ARGS[@]}" --wait
        xcrun stapler staple "$DMG_IMAGE"
        xcrun stapler validate "$DMG_IMAGE"
    fi
fi
python3 scripts/verify-dmg.py "$DMG_IMAGE" "${VERIFY_ARGS[@]}"

# 所有产物创建和验证成功后才替换输出，避免暴露未完成的镜像。
/bin/mkdir -p "$PACKAGE_WORK/previous"
PUBLISH_STARTED=1
for OUTPUT_NAME in "${OUTPUT_NAMES[@]}"; do
    if [[ -e "$DIST/$OUTPUT_NAME" ]]; then
        /bin/mv -- "$DIST/$OUTPUT_NAME" "$PACKAGE_WORK/previous/$OUTPUT_NAME"
    fi
done
for OUTPUT_NAME in "${OUTPUT_NAMES[@]}"; do
    /bin/mv -- "$PACKAGE_WORK/$OUTPUT_NAME" "$DIST/$OUTPUT_NAME"
done
PUBLISH_DONE=1
print -r -- "$FINAL_APP" "$FINAL_ZIP" "$FINAL_DMG"
