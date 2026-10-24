#!/bin/bash
# 生成正式频道的全量 Sparkle 更新包，必须完成 Developer ID 签名与 Apple 公证。
# 私钥从 Keychain 或 SPARKLE_PRIVATE_KEY（经 stdin）读取，绝不进入仓库或命令参数。
set -euo pipefail
umask 077
# 私钥只交给最后的签名工具；Xcode/构建脚本不能继承它或把它写进构建日志。
sparkle_private_key="${SPARKLE_PRIVATE_KEY:-}"
unset SPARKLE_PRIVATE_KEY
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
case "${1:-notarized}" in notarized) ;; *) echo "usage: $0 [notarized]" >&2; exit 1 ;; esac
: "${RELEASE_TAG:?请设置 RELEASE_TAG（例如 v9.5.0）}"
repository="${GITHUB_REPOSITORY:-oceanix-pr/Memonta}"
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
   [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: 仓库或 tag 格式无效" >&2; exit 1
fi
: "${APPLE_TEAM_ID:?正式发布需要 APPLE_TEAM_ID}"
if [ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    : "${NOTARY_KEY_FILE:?正式发布需要 NOTARY_KEYCHAIN_PROFILE 或 NOTARY_KEY_FILE}"
    : "${NOTARY_KEY_ID:?需要 NOTARY_KEY_ID}"
    : "${NOTARY_ISSUER_ID:?需要 NOTARY_ISSUER_ID}"
fi
work="${RELEASE_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/memonta-release.XXXXXX")}"
mkdir -p "$work"
packages="${PACKAGE_CACHE_PATH:-$work/DerivedData/SourcePackages}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9.]*\)".*/\1/p' project.yml | head -1)"
build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | head -1)"
expected_tag="v$version"
if [ "$RELEASE_TAG" != "$expected_tag" ]; then
    echo "error: tag 与 project.yml 版本不一致" >&2; exit 1
fi
xcodegen generate
common=(-skipPackageUpdates -project Memonta.xcodeproj -scheme Memonta -configuration Release
        -destination 'platform=macOS' -derivedDataPath "$work/DerivedData"
        -clonedSourcePackagesDirPath "$packages" MEMONTA_PACKAGE_CACHE_PATH="$packages"
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        MEMONTA_UPDATE_FEED_URL="https://raw.githubusercontent.com/$repository/updates/stable/appcast.xml")
xcodebuild "${common[@]}" -archivePath "$work/Memonta.xcarchive" \
    CODE_SIGN_IDENTITY='Developer ID Application' CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp archive
python3 - "$work/export.plist" "$APPLE_TEAM_ID" <<'PYEXPORT'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
 plistlib.dump({'method':'developer-id', 'teamID':sys.argv[2], 'signingStyle':'manual'},f)
PYEXPORT
xcodebuild -exportArchive -archivePath "$work/Memonta.xcarchive" \
    -exportPath "$work/export" -exportOptionsPlist "$work/export.plist"
app="$work/export/Memonta.app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization.zip"
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$work/notarization.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait --output-format json > "$work/notarization.json"
else
    xcrun notarytool submit "$work/notarization.zip" --key "$NOTARY_KEY_FILE" \
        --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
        --wait --output-format json > "$work/notarization.json"
fi
python3 - "$work/notarization.json" <<'PYNOTARY'
import json, sys
r=json.load(open(sys.argv[1]))
if r.get('status') != 'Accepted': raise SystemExit('公证未通过，禁止发布')
PYNOTARY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
codesign --verify --deep --strict "$app"
# 校验导出包实际版本与动态库引用，不能只信任 workflow 输入。
python3 - "$app" "$version" "$build" <<'PYVERIFY'
import base64, pathlib, plistlib, subprocess, sys
app=pathlib.Path(sys.argv[1])
d=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert d['CFBundleShortVersionString']==sys.argv[2], '营销版本不一致'
assert d['CFBundleVersion']==sys.argv[3], '构建号不一致'
assert len(base64.b64decode(d['SUPublicEDKey']))==32, '更新公钥无效'
assert d['SUFeedURL'].endswith('/updates/stable/appcast.xml') and d['SUFeedURL'].startswith('https://raw.githubusercontent.com/'), '更新 feed 必须使用正式频道'
assert d['SUAllowsAutomaticUpdates'] is False, '不能开启静默安装'
assert d['SUEnableSystemProfiling'] is False, '不能开启系统画像'
for binary in (app/'Contents/Frameworks').rglob('SherpaOnnxC'):
 if binary.is_file():
  linked=subprocess.check_output(['otool','-L',str(binary)],text=True)
  assert '@rpath/libonnxruntime.dylib' not in linked, 'ONNX 引用无效'
entitlements=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True)
if entitlements.stdout.strip():
 assert not plistlib.loads(entitlements.stdout).get('com.apple.security.get-task-allow',False), '发布包含调试权限'
PYVERIFY
out="$work/updates"
mkdir -p "$out"
archive="Memonta-${RELEASE_TAG}-${build}-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$archive"
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    cp "$RELEASE_NOTES_FILE" "$out/${archive%.zip}.md"
elif [ -f "$root/docs/releases/$version.md" ]; then
    cp "$root/docs/releases/$version.md" "$out/${archive%.zip}.md"
else
    printf 'Memonta %s (%s)\n' "$version" "$build" > "$out/${archive%.zip}.md"
fi
sparkle_bin="${SPARKLE_BIN_DIR:-$packages/artifacts/sparkle/Sparkle/bin}"
if [ ! -x "$sparkle_bin/generate_appcast" ]; then
    echo "error: 未找到 Sparkle 工具，请设置 SPARKLE_BIN_DIR" >&2; exit 1
fi
args=(--maximum-deltas 0 --download-url-prefix "https://github.com/$repository/releases/download/$RELEASE_TAG/"
      --embed-release-notes "$out")
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    "$sparkle_bin/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${args[@]}"
elif [ -n "$sparkle_private_key" ]; then
    printf '%s' "$sparkle_private_key" | "$sparkle_bin/generate_appcast" --ed-key-file - "${args[@]}"
else
    "$sparkle_bin/generate_appcast" --account com.oceanix.Memonta.sparkle "${args[@]}"
fi
python3 - "$out/appcast.xml" "$out/$archive" "$build" <<'PYFEED'
import pathlib, sys, xml.etree.ElementTree as E
root=E.parse(sys.argv[1]); item=root.find('channel/item'); assert item is not None
ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item.findtext(ns+'version')==sys.argv[3], 'feed 构建号不一致'
e=item.find('enclosure'); assert e is not None and e.get(ns+'edSignature'), '缺少更新签名'
assert int(e.get('length'))==pathlib.Path(sys.argv[2]).stat().st_size, '更新包长度不一致'
PYFEED
(cd "$out" && shasum -a 256 "$archive" appcast.xml > SHA256SUMS)
printf '更新包已生成：%s\n' "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'directory=%s\n' "$out" >> "$GITHUB_OUTPUT"; fi
