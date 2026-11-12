#!/bin/bash
set -euo pipefail
# No unsigned artifact is treated as a signed public release.
if [[ -z "${MACOS_CERTIFICATE_P12:-}" ]]; then
  echo 'SHANCHUAN_UNSIGNED_CI=1' >> "$GITHUB_ENV"
  echo 'signed=false' >> "$GITHUB_OUTPUT"
  exit 0
fi
: "${MACOS_CERTIFICATE_PASSWORD:?缺少证书密码}"
: "${APPLE_ID:?缺少公证 Apple ID}"
: "${APPLE_TEAM_ID:?缺少 Team ID}"
: "${APPLE_APP_PASSWORD:?缺少公证密码}"
KEYCHAIN="$RUNNER_TEMP/shanchuan-signing.keychain-db"
P12="$RUNNER_TEMP/shanchuan-signing.p12"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
trap 'rm -f "$P12"' EXIT
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -P "$MACOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Developer ID Application:/ {print $2}')"
[[ $(printf '%s\n' "$IDENTITY" | wc -l | tr -d ' ') = 1 && -n "$IDENTITY" ]] || { echo '需要唯一的 Developer ID Application 身份' >&2; exit 1; }
xcrun notarytool store-credentials shanchuan-notary --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --keychain "$KEYCHAIN"
echo "COPYTOOL_SIGNING_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo 'NOTARY_KEYCHAIN_PROFILE=shanchuan-notary' >> "$GITHUB_ENV"
echo 'signed=true' >> "$GITHUB_OUTPUT"
