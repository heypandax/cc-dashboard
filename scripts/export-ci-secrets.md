# CI Secrets 导出速查

把本机 keychain 里的凭据搬到 GitHub Secrets。一次性,弄完 `.github/workflows/release.yml` 就能用 workflow_dispatch 发版。

**GitHub Secrets 路径**:
`github.com/heypandax/cc-dashboard/settings/secrets/actions` → New repository secret

需要的 8 条 secrets:

| Name | 作用 |
|------|------|
| `MACOS_CERTIFICATE` | Developer ID Application `.p12` 的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导 `.p12` 时设的密码 |
| `KEYCHAIN_PASSWORD` | 给 CI runner 临时 keychain 解锁用,任意字符串即可 |
| `APPLE_API_KEY_P8` | ASC API Key 的 `.p8` 文件 base64 |
| `APPLE_API_KEY_ID` | ASC API Key ID(10 位字符) |
| `APPLE_API_ISSUER` | ASC Issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA 私钥 base64 |
| `TAP_REPO_TOKEN` | GitHub PAT,写 `homebrew-cc-dashboard` 用 |

---

## 1. MACOS_CERTIFICATE + MACOS_CERTIFICATE_PASSWORD

导出 Developer ID Application 证书和私钥成 `.p12`。

**钥匙串访问 GUI**(最稳):
1. Keychain Access → login keychain → Certificates
2. 找 `Developer ID Application: lee davin (SC9S2SJ42G)`
3. **展开它**(点箭头),里面应该有一个同名私钥 —— **选证书 + 私钥两项一起** → 右键 → Export 2 items
4. 格式选 `.p12`,路径 `~/cert.p12`
5. 弹窗设 `.p12` 密码(要够强,将来贴进 secret)

然后:
```bash
base64 -i ~/cert.p12 | pbcopy
# 粘进 MACOS_CERTIFICATE secret
rm ~/cert.p12   # 别留在磁盘
```

`MACOS_CERTIFICATE_PASSWORD` = 上一步设的密码。

## 2. KEYCHAIN_PASSWORD

任意字符串,workflow 用它解锁临时 keychain。不是敏感信息,但生成强随机更好:

```bash
openssl rand -base64 32 | pbcopy
# 粘进 KEYCHAIN_PASSWORD secret
```

## 3. APPLE_API_KEY_P8 + KEY_ID + ISSUER

ASC API Key 对应的 `.p8`。你之前 `store-credentials` 时填过,应该还留着 p8 文件:

```bash
# 如果还找得到原 .p8
base64 -i ~/private_keys/AuthKey_XXXXXXXXXX.p8 | pbcopy
# 粘进 APPLE_API_KEY_P8 secret
```

如果 **找不到了**:App Store Connect 里重新生成(旧的 revoke):
- https://appstoreconnect.apple.com/access/integrations/api
- Team Keys → Generate → 选 Developer role → 下载 `.p8`(**只下载一次的机会**)
- `Key ID`(10 位)和 `Issuer ID`(UUID)页面上有

`APPLE_API_KEY_ID` = 文件名里那 10 位 `XXXXXXXXXX`,或 ASC 网页上 Key ID 列。
`APPLE_API_ISSUER` = ASC 网页顶部 Issuer ID 字段。

## 4. SPARKLE_PRIVATE_KEY

从 keychain 导出 EdDSA 私钥:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle_private.key
base64 -i ~/sparkle_private.key | pbcopy
# 粘进 SPARKLE_PRIVATE_KEY secret
rm ~/sparkle_private.key   # 立即删
```

**重要**:这一串泄露 = 任何人能给你的老用户推任意更新包。别提交 repo,别截图,别贴 Slack。

## 5. TAP_REPO_TOKEN

GitHub PAT,让 workflow 写 `heypandax/homebrew-cc-dashboard`(默认 `GITHUB_TOKEN` 只能写当前主仓)。用 **fine-grained** PAT 最小权限:

1. https://github.com/settings/personal-access-tokens/new
2. Token name: `cc-dashboard release tap push`
3. Expiration: 按需(建议 1 年)
4. Repository access → **Only select repositories** → 选 `heypandax/homebrew-cc-dashboard`
5. Repository permissions:
   - **Contents: Read and write**(唯一必需)
   - 其他都 No access
6. Generate token,复制 → 粘进 `TAP_REPO_TOKEN` secret

## 触发发版

配齐后,`gh` 或网页:

```bash
gh workflow run Release -f version=0.1.1
# 或者 actions 页面点 "Run workflow"
```

workflow 会:bump → notarize → appcast → cask → tag → push → Release → tap sync → Pages。大约 8-12 分钟。

## 验证链路没问题

第一次跑先 **试一个 throwaway 版本号** 比如 `0.1.1-test` —— 哦不,semver regex 只认 `X.Y.Z`。要么就直接跑真 0.1.1,要么改 workflow regex 放开 `-test` 后缀。

简单起见:直接发 0.1.1。如果 workflow 中间挂,已推的 commit 和 tag 可以:

```bash
git push origin :v0.1.1         # 删 remote tag
git tag -d v0.1.1               # 删本地 tag
git revert <bump-commit>        # 或 reset 撤 bump
gh release delete v0.1.1 -y     # 删 Release
```

tap 仓 push 冲突时类似。workflow 每步都有 timestamp,挂在哪眼就看出来。
