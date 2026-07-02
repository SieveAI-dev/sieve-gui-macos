# 发布指南

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI

---

## 0. 摘要

Sieve GUI 的发布走 **hardened runtime + Apple notarization + Sparkle EdDSA 签名** 三层。
分发载体是 `.dmg`（用户拖拽到 Applications）+ Sparkle appcast（自动检查更新）。

---

## 1. 一次性准备

### 1.1 Apple Developer 账号

- Account → Certificates → 申请 `Developer ID Application` 证书（**不**是 Mac App Store 那种）
- 把证书导入本机 Keychain（双击 .p12 文件，输入密码）
- 确认在 `Keychain Access` 里看得到证书 + 私钥

```bash
# 验证
security find-identity -v -p codesigning
# 应该看到一行 "Developer ID Application: <Your Name> (<TEAMID>)"
```

### 1.2 notarytool 凭证

```bash
# 用 App-Specific Password（在 appleid.apple.com 创建）
xcrun notarytool store-credentials sieve-notary \
  --apple-id "you@example.com" \
  --team-id "<TEAMID>" \
  --password "<app-specific-password>"
```

凭证存进 Keychain，后续用 `--keychain-profile sieve-notary` 引用。

### 1.3 Sparkle EdDSA 密钥对

```bash
# 一次性生成
brew install --cask sparkle
generate_keys
# 输出公钥、私钥
```

**关键约束**：
- **公钥** hardcode 进 GUI 的 `Info.plist`（key: `SUPublicEDKey`）
- **私钥**保存到密码管理器，**不入 git**
- 私钥泄漏 = 灾难（攻击者可发恶意更新），泄漏立即换 keypair + 强制下个版本走 .dmg 重装

### 1.4 appcast 主机

appcast 由静态托管提供（任意静态站均可）：
- 域名：`updates.sieveai.dev`
- appcast 路径：`https://updates.sieveai.dev/appcast.xml`

---

## 2. 构建流程

### 2.1 archive

```bash
# 在仓库根
xcodebuild archive \
  -project SieveGUI.xcodeproj \
  -scheme SieveGUI \
  -configuration Release \
  -archivePath build/SieveGUI.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=<TEAMID>
```

### 2.2 export .app

```bash
xcodebuild -exportArchive \
  -archivePath build/SieveGUI.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist scripts/exportOptions.plist
```

`scripts/exportOptions.plist`（已在仓库内）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>(TEAMID)</string>
</dict>
</plist>
```

### 2.3 验证签名

```bash
codesign --verify --deep --strict --verbose=2 build/export/SieveGUI.app
spctl --assess --type execute --verbose build/export/SieveGUI.app
```

两条都应通过。如果 `spctl` 报错"rejected (the code is valid but does not seem to be an app)"，检查是否有未签名的内嵌 framework。

### 2.4 检查 entitlements

```bash
codesign -d --entitlements - build/export/SieveGUI.app
```

应该看到（关键项）：

```
com.apple.security.app-sandbox: false      ← Phase 1 不 sandbox
com.apple.security.network.client: false   ← 表意图；非沙箱下不被 OS 强制（真实保证是架构约束：决策链路零网络客户端）
com.apple.security.cs.allow-jit: false
com.apple.security.cs.disable-library-validation: false
com.apple.security.files.user-selected.read-write: true
```

注意：app-sandbox = false 时网络 entitlement 没有运行时效果（网络类 entitlement 仅在 App Sandbox 开启时由 OS 强制）。「决策路径不联网」的真实保证是架构约束（HIPS/决策链路不引用任何网络客户端，网络出口仅 Sparkle）；Sparkle 的 appcast host 白名单经 `Info.plist` 的 `NSAppTransportSecurity` `NSExceptionDomains` 收敛。

---

## 3. notarization

### 3.1 打包 .zip 提交

```bash
ditto -c -k --sequesterRsrc --keepParent \
  build/export/SieveGUI.app \
  build/SieveGUI.zip

xcrun notarytool submit build/SieveGUI.zip \
  --keychain-profile sieve-notary \
  --wait
```

`--wait` 阻塞到 notary 完成（通常 1~5 分钟）。
失败时拿 `submission_id` 查日志：

```bash
xcrun notarytool log <submission_id> --keychain-profile sieve-notary
```

### 3.2 staple

```bash
xcrun stapler staple build/export/SieveGUI.app
xcrun stapler validate build/export/SieveGUI.app
```

`stapler validate` 输出 "The validate action worked!" 即成功。

---

## 4. 打 .dmg

```bash
# 用 create-dmg（Homebrew 可装）
brew install create-dmg

create-dmg \
  --volname "Sieve GUI" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "SieveGUI.app" 175 200 \
  --hide-extension "SieveGUI.app" \
  --app-drop-link 425 200 \
  build/SieveGUI-0.1.0-alpha.dmg \
  build/export/
```

签名 .dmg：

```bash
codesign --force --sign "Developer ID Application: <Your Name> (<TEAMID>)" \
  build/SieveGUI-0.1.0-alpha.dmg

# notarize .dmg（再走一次）
xcrun notarytool submit build/SieveGUI-0.1.0-alpha.dmg \
  --keychain-profile sieve-notary \
  --wait

xcrun stapler staple build/SieveGUI-0.1.0-alpha.dmg
```

---

## 5. Sparkle appcast

### 5.1 签 .dmg

```bash
sign_update build/SieveGUI-0.1.0-alpha.dmg
# 输出 sparkle:edSignature 和 length 两个值
```

### 5.2 更新 appcast.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sieve GUI Updates</title>
    <link>https://&lt;host&gt;/appcast.xml</link>
    <item>
      <title>Version 0.1.0-alpha</title>
      <pubDate>Thu, 02 May 2026 12:00:00 +0000</pubDate>
      <sparkle:version>20260502.1</sparkle:version>
      <sparkle:shortVersionString>0.1.0-alpha</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://&lt;host&gt;/SieveGUI-0.1.0-alpha.dmg"
        sparkle:edSignature="&lt;EdDSA-signature&gt;"
        length="&lt;byte-length&gt;"
        type="application/octet-stream" />
      <description><![CDATA[
        <h2>Sieve GUI 0.1.0-alpha</h2>
        <p>早期预览版本。</p>
      ]]></description>
    </item>
  </channel>
</rss>
```

`sparkle:version` 用单调递增整数（不一定等于 marketing version）。

### 5.3 上传 .dmg + appcast.xml 到静态托管

托管目录结构：

```
sieve-gui-appcast/
├── appcast.xml
├── SieveGUI-0.1.0-alpha.dmg
└── ...                  ← 保留历史版本，便于回退
```

部署后即可被客户端拉取。

### 5.4 验证

在另一台 Mac 装老版本，跑设置 → Updates → 检查更新，应该弹出升级提示，签名校验通过，下载安装。

---

## 6. 版本号约定

| 字段 | 来源 | 示例 |
|------|-----|------|
| `CFBundleShortVersionString` | `Info.plist` | `0.1.0-alpha`（marketing） |
| `CFBundleVersion` | `Info.plist` | `20260502.1`（build，单调递增） |
| `sparkle:version` | appcast.xml | 同 build |
| `sparkle:shortVersionString` | appcast.xml | 同 marketing |

build 号格式：`YYYYMMDD.<同日发布序号>`。

---

## 7. 回退流程

发现某个版本严重 bug，需要让用户自动回退到上个版本：

1. **不能强制降级**（Sparkle 不支持）
2. 但可以发一个新版本（version 高于问题版本，但实质是上个版本的代码 + 一行改 build 号）
3. 在 release notes 注明"修复 X 严重问题"

或者更彻底：
- 把问题版本从 appcast 移除
- 用户已装的不会自动卸载，但他们再开"检查更新"时不会再被推问题版本

---

## 8. 反复出现的坑

### 8.1 notarization 失败：`The signature of the binary is invalid`

通常是某个内嵌 framework 没签到。检查：

```bash
codesign --verify --deep --strict build/export/SieveGUI.app/Contents/Frameworks/*.framework
```

逐个签：

```bash
codesign --force --options runtime --sign "<identity>" \
  build/export/SieveGUI.app/Contents/Frameworks/SQLite.framework
```

然后整体重签：

```bash
codesign --force --deep --options runtime --sign "<identity>" build/export/SieveGUI.app
```

### 8.2 Sparkle 报 "Update is improperly signed"

- EdDSA 公钥在 `Info.plist` 里和签名时用的私钥不匹配
- 重新跑 `sign_update`，确认输出的 `edSignature` 与 appcast 里一致

### 8.3 用户右键 → 打开仍然提示"无法验证开发者"

stapler 没成功 / 用户的 macOS 离线无法在线验证 → 让用户跑：

```bash
xattr -d com.apple.quarantine /Applications/SieveGUI.app
```

如果是大量用户报同问题，重新跑 stapler 后重新发版。

---

## 9. 发布前自检清单

- [ ] 所有测试通过（`swift test`）+ App 构建通过（`xcodebuild build`）
- [ ] `swiftformat --lint` 通过
- [ ] `Info.plist` 版本号已递增
- [ ] CHANGELOG.md 已更新
- [ ] notarization 通过
- [ ] stapler 验证通过
- [ ] .dmg 在另一台 Mac 上能一键安装（不弹"无法验证开发者"）
- [ ] appcast 签名可以被老版本验证
- [ ] 回归测试：HIPS 主流程 + 菜单栏 + 历史 + 设置切 preset
- [ ] 上游 daemon 仓库的 protocol_version 兼容确认

通过后再 push appcast。
