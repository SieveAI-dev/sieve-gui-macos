#!/usr/bin/env bash
# notarize.sh — Sieve GUI Apple Notarization + staple 脚本
# 用法：./scripts/notarize.sh <path-to.dmg>
# 完整发布流程：docs/guides/deployment.md §3
#
# 必需环境变量（凭证不硬编码，在 CI / 本地发布时注入）：
#   APPLE_ID               — Apple ID 邮箱（在 appleid.apple.com 管理）
#   APPLE_TEAM_ID          — Developer Team ID（10 位字母数字）
#   APP_SPECIFIC_PASSWORD  — App 专用密码（在 appleid.apple.com 创建，格式 xxxx-xxxx-xxxx-xxxx）
set -euo pipefail

DMG_PATH="${1:?用法：./scripts/notarize.sh <path-to.dmg>}"

# 环境变量校验（fail fast，不等到 notarytool 才报错）
: "${APPLE_ID:?请设置 APPLE_ID 环境变量（Apple ID 邮箱）}"
: "${APPLE_TEAM_ID:?请设置 APPLE_TEAM_ID 环境变量（10 位 Team ID）}"
: "${APP_SPECIFIC_PASSWORD:?请设置 APP_SPECIFIC_PASSWORD 环境变量（App 专用密码）}"

echo "==> Notarizing: ${DMG_PATH}"
echo "    Apple ID: ${APPLE_ID}"
echo "    Team ID : ${APPLE_TEAM_ID}"

echo "==> Step 1: xcrun notarytool submit"
/usr/bin/xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APP_SPECIFIC_PASSWORD}" \
    --wait

echo "==> Step 2: xcrun stapler staple"
/usr/bin/xcrun stapler staple "${DMG_PATH}"

echo "==> Step 3: xcrun stapler validate"
/usr/bin/xcrun stapler validate "${DMG_PATH}"

echo "✅ Notarization 完成：${DMG_PATH}"
echo "   下一步：sign_update ${DMG_PATH} → 更新 appcast.xml → 上传到 CDN"
