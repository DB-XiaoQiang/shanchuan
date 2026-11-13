#!/bin/zsh
# 只生成独立的更新测试应用；不改变正式 VERSION、资源公钥或发布通道。
set -euo pipefail
cd "${0:A:h:h}"

usage() {
    cat <<'USAGE'
用法：scripts/package-update-test.sh \
  --version 0.1.3 --build-number 1003 \
  --manifest-public-key /外部目录/test-update-public-key.pem \
  --sparkle-public-key /外部目录/test-sparkle-public-key.txt \
  [--target-version 0.1.4] [--output /全新输出目录]

只接受测试公钥。私钥不传入此脚本、不复制到应用中。
COPYTOOL_SIGNING_IDENTITY 可指定稳定签名身份；未指定时选择唯一 Apple Development 身份。
输出为“闪传更新测试.app”和 ShanchuanUpdateTest-macos-arm64.zip，不启动应用。
USAGE
}

TEST_VERSION=""
TEST_BUILD_NUMBER=""
MANIFEST_PUBLIC_KEY_FILE=""
SPARKLE_PUBLIC_KEY_FILE=""
TARGET_VERSION="0.1.4"
TEST_OUTPUT=""
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --version|--build-number|--manifest-public-key|--sparkle-public-key|--target-version|--output)
            (( $# >= 2 )) || { print -u2 "缺少参数值：$1"; exit 2; }
            case "$1" in
                --version) TEST_VERSION="$2" ;;
                --build-number) TEST_BUILD_NUMBER="$2" ;;
                --manifest-public-key) MANIFEST_PUBLIC_KEY_FILE="$2" ;;
                --sparkle-public-key) SPARKLE_PUBLIC_KEY_FILE="$2" ;;
                --target-version) TARGET_VERSION="$2" ;;
                --output) TEST_OUTPUT="$2" ;;
            esac
            shift 2 ;;
        *) print -u2 "未知参数：$1"; usage >&2; exit 2 ;;
    esac
done
[[ -n "$TEST_VERSION" && -n "$TEST_BUILD_NUMBER" && -n "$MANIFEST_PUBLIC_KEY_FILE" && -n "$SPARKLE_PUBLIC_KEY_FILE" ]] || {
    usage >&2; exit 2
}
[[ "$TEST_VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' &&
   "$TARGET_VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' &&
   "$TEST_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || {
    print -u2 '测试版本须为三段版本号，构建号须为正整数。'; exit 2
}
[[ "${SHANCHUAN_UNSIGNED_CI:-0}" != 1 ]] || {
    print -u2 '实际更新测试需要稳定签名身份，不接受无签名 CI 模式。'; exit 2
}
[[ "$TARGET_VERSION" == '0.1.4' ]] || {
    print -u2 '当前独立测试通道只接受已确认的目标 0.1.4。'; exit 2
}

MANIFEST_PUBLIC_KEY_FILE="${MANIFEST_PUBLIC_KEY_FILE:A}"
SPARKLE_PUBLIC_KEY_FILE="${SPARKLE_PUBLIC_KEY_FILE:A}"
[[ -f "$MANIFEST_PUBLIC_KEY_FILE" && -f "$SPARKLE_PUBLIC_KEY_FILE" ]] || {
    print -u2 '找不到外部测试公钥文件。'; exit 2
}
# 校验格式及隔离身份，只输出简短结果，绝不输出文件内容。
python3 - "$MANIFEST_PUBLIC_KEY_FILE" "$SPARKLE_PUBLIC_KEY_FILE" <<'PY'
import base64
import pathlib
import re
import subprocess
import sys

def pem_bytes(path):
    data = pathlib.Path(path).read_text().strip()
    match = re.fullmatch(r'-----BEGIN PUBLIC KEY-----\s+([A-Za-z0-9+/=\s]+)\s+-----END PUBLIC KEY-----', data)
    if not match:
        raise ValueError('必须提供 PUBLIC KEY 格式的测试公钥，不能提供私钥。')
    return base64.b64decode(''.join(match.group(1).split()), validate=True)

try:
    manifest = pem_bytes(sys.argv[1])
    if manifest == pem_bytes('Resources/update-public-key.pem'):
        raise ValueError('测试发行公钥必须与正式公钥不同。')
    checked = subprocess.run(['/usr/bin/openssl', 'pkey', '-pubin', '-in', sys.argv[1], '-text', '-noout'],
                             capture_output=True, text=True)
    if checked.returncode or not any(curve in checked.stdout for curve in ('prime256v1', 'P-256')):
        raise ValueError('测试发行公钥必须是 ECDSA P-256 公钥。')
    sparkle = base64.b64decode(pathlib.Path(sys.argv[2]).read_text().strip(), validate=True)
    production = base64.b64decode(pathlib.Path('Resources/sparkle-public-key.txt').read_text().strip(), validate=True)
    if len(sparkle) != 32:
        raise ValueError('测试 Sparkle 公钥必须为 Base64 编码的 32 字节公钥。')
    if sparkle == production:
        raise ValueError('测试 Sparkle 公钥必须与正式公钥不同。')
except (OSError, ValueError) as error:
    sys.exit(str(error))
print('测试公钥格式及独立性检查通过。')
PY

SIGNING_IDENTITY="${COPYTOOL_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITIES=( ${(f)"$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')"} )
    (( ${#SIGNING_IDENTITIES} == 1 )) || {
        print -u2 '请通过 COPYTOOL_SIGNING_IDENTITY 指定稳定的本机测试签名身份。'; exit 2
    }
    SIGNING_IDENTITY="$SIGNING_IDENTITIES[1]"
fi
[[ "$SIGNING_IDENTITY" != '-' ]] || { print -u2 '测试应用不使用 ad hoc 签名。'; exit 2; }

TEST_OUTPUT="${TEST_OUTPUT:-$PWD/dist/update-test/$TEST_VERSION}"
TEST_OUTPUT="${TEST_OUTPUT:A}"
[[ ! -e "$TEST_OUTPUT" && ! -L "$TEST_OUTPUT" ]] || {
    print -u2 '测试输出目录已经存在，拒绝覆盖。请明确选择新的输出目录。'; exit 2
}
/bin/mkdir -p "${TEST_OUTPUT:h}"
TEST_WORK="$(/usr/bin/mktemp -d "${TEST_OUTPUT:h}/.shanchuan-update-test-build.XXXXXX")"
cleanup_test_package() { local result=$?; /bin/rm -rf -- "$TEST_WORK"; return $result; }
trap cleanup_test_package EXIT

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$TEST_WORK/闪传更新测试.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
/bin/cp "$BIN_DIR/CopyTool" "$APP/Contents/MacOS/CopyTool"
/bin/cp Resources/AppIcon.icns Resources/AppIcon.png "$APP/Contents/Resources/"
/bin/cp "$MANIFEST_PUBLIC_KEY_FILE" "$APP/Contents/Resources/update-public-key.pem"
/bin/cp "$SPARKLE_PUBLIC_KEY_FILE" "$APP/Contents/Resources/sparkle-public-key.txt"

python3 - "$APP" "$TEST_VERSION" "$TEST_BUILD_NUMBER" "$TARGET_VERSION" "$SPARKLE_PUBLIC_KEY_FILE" <<'PY'
import pathlib
import plistlib
import sys
app, version, build, target, sparkle_file = sys.argv[1:]
info = {
    'CFBundleIdentifier': 'local.copytool.update-test', 'CFBundleExecutable': 'CopyTool',
    'CFBundleName': '闪传更新测试', 'CFBundleDisplayName': '闪传更新测试',
    'CFBundleIconFile': 'AppIcon.icns', 'CFBundlePackageType': 'APPL',
    'NSPrincipalClass': 'NSApplication', 'CFBundleShortVersionString': version,
    'CFBundleVersion': build, 'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'NSHumanReadableCopyright': 'Independent implementation, isolated update test',
    'ShanchuanUpdateTest': True, 'ShanchuanUpdateTestTargetVersion': target,
    'SUFeedURL': f'https://github.com/DB-XiaoQiang/shanchuan/releases/download/update-test-v{target}/appcast.xml',
    'SUPublicEDKey': pathlib.Path(sparkle_file).read_text().strip(),
    'SUEnableAutomaticChecks': False, 'SUAllowsAutomaticUpdates': False,
    'SUAutomaticallyUpdate': False, 'SUAutomaticallyDownloadUpdates': False,
}
with (pathlib.Path(app) / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream, sort_keys=False)
PY

FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
    FRAMEWORK="$(/usr/bin/find .build/artifacts -path '*/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit)"
fi
[[ -d "$FRAMEWORK" ]] || { print -u2 '缺少 Sparkle.framework'; exit 1; }
/usr/bin/ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
python3 scripts/stage-localizations.py "$APP" "$BIN_DIR/CopyTool_CopyToolCore.bundle"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for NESTED in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$NESTED" ]] || { print -u2 '缺少测试包的 Sparkle 签名目标。'; exit 1; }
    codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=identifier,entitlements --options runtime --timestamp "$NESTED"
done
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$TEST_WORK/ShanchuanUpdateTest-macos-arm64.zip"

python3 - "$APP" "$TEST_WORK/build-info.json" <<'PY'
import json
import pathlib
import plistlib
import sys
with (pathlib.Path(sys.argv[1]) / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'local.copytool.update-test' and info['ShanchuanUpdateTest'] is True
report = {'product': 'ShanchuanUpdateTest', 'version': info['CFBundleShortVersionString'],
          'buildNumber': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
          'targetVersion': info['ShanchuanUpdateTestTargetVersion'], 'testChannel': True,
          'codeSignatureVerified': True, 'notarized': False}
pathlib.Path(sys.argv[2]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
PY
# 只在所有内容及签名验证完成后公开这个全新的版本目录。
/bin/mv -- "$TEST_WORK" "$TEST_OUTPUT"
print -r -- "$TEST_OUTPUT/闪传更新测试.app" "$TEST_OUTPUT/ShanchuanUpdateTest-macos-arm64.zip" "$TEST_OUTPUT/build-info.json"
