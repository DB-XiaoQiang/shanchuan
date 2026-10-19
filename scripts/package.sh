#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
SIGNING_IDENTITY="${COPYTOOL_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
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
swift build
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
/bin/cp .build/debug/CopyTool "$APP/Contents/MacOS/CopyTool"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Independent implementation, 2026</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$PACKAGE_WORK/闪传-macos-arm64.zip"
if [[ -e "$FINAL_APP" ]]; then
    /bin/mv -- "$FINAL_APP" "$PACKAGE_WORK/previous.app"
fi
/bin/mv -- "$APP" "$FINAL_APP"
/bin/mv -f -- "$PACKAGE_WORK/闪传-macos-arm64.zip" "$FINAL_ZIP"
print -r -- "$FINAL_APP"
