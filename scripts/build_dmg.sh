#!/usr/bin/env bash
# build_dmg.sh — Sieve GUI .dmg 打包脚本骨架
# 用法：./scripts/build_dmg.sh [VERSION]
# 完整发布流程：docs/guides/deployment.md
#
# 依赖：Xcode Command Line Tools、codesign（系统内置）
# 注意：签名需要本机 Keychain 里有 "Developer ID Application" 证书
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

VERSION="${1:-$(xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI -showBuildSettings 2>/dev/null | awk '/MARKETING_VERSION/{print $3; exit}')}"
if [[ -z "${VERSION}" ]]; then
    echo "❌ 无法确定版本号，请手动传入：./scripts/build_dmg.sh 0.1.0" >&2
    exit 1
fi

ARCHIVE_PATH="build/SieveGUI.xcarchive"
EXPORT_PATH="build/export"
DMG_OUT="build/SieveGUI-${VERSION}.dmg"

echo "==> 版本：${VERSION}"
echo "==> Step 1: xcodebuild archive"
/usr/bin/xcodebuild archive \
    -project SieveGUI.xcodeproj \
    -scheme SieveGUI \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="Developer ID Application: ${APPLE_SIGN_IDENTITY:?请设置 APPLE_SIGN_IDENTITY 环境变量}" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:?请设置 APPLE_TEAM_ID 环境变量}"

echo "==> Step 2: xcodebuild exportArchive"
/usr/bin/xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist scripts/exportOptions.plist

echo "==> Step 3: 验证代码签名"
codesign --verify --deep --strict --verbose=2 "${EXPORT_PATH}/SieveGUI.app"

echo "==> Step 4: hdiutil create .dmg"
# 用 hdiutil（系统内置，无第三方依赖）
TMP_DIR="$(mktemp -d)"
cp -R "${EXPORT_PATH}/SieveGUI.app" "${TMP_DIR}/"
ln -s /Applications "${TMP_DIR}/Applications"
hdiutil create \
    -volname "Sieve GUI ${VERSION}" \
    -srcfolder "${TMP_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_OUT}"
rm -rf "${TMP_DIR}"

echo "==> Step 5: 签名 .dmg"
codesign --force --sign \
    "Developer ID Application: ${APPLE_SIGN_IDENTITY}" \
    "${DMG_OUT}"

echo "✅ 完成：${DMG_OUT}"
echo "   下一步：./scripts/notarize.sh ${DMG_OUT}"
