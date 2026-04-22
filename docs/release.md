# Releasing a signed build

CI handles the standard release path — see
[`.github/workflows/release.yml`](../.github/workflows/release.yml). This
document covers local builds for distribution (e.g. before CI is wired, or
for testing a signed binary on someone else's Mac).

## One-time: store an App Store Connect API key

To run on someone else's Mac, the build needs Apple notarization —
otherwise Gatekeeper blocks it.

Create a Developer-role team key at **ASC → Users and Access → Integrations
→ Team Keys**, download the `.p8`, then:

```bash
xcrun notarytool store-credentials "cc-dashboard-notary" \
  --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

## Each release

```bash
CC_NOTARIZE=1 ./make-bundle.sh
# Output: dist/cc-dashboard.dmg (ticket stapled — recipients just
# double-click and drag to Applications)
```

Override the profile name with `CC_NOTARY_PROFILE=xxx` (default:
`cc-dashboard-notary`).

## Build configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `CC_SIGN_IDENTITY` | `Developer ID Application: …` | Override the codesign identity. Set to `-` for ad-hoc signing (local debug only; cannot be notarized). |
| `CC_NOTARIZE` | `0` | Set to `1` to build a DMG, submit to Apple notary, and staple the ticket. |
| `CC_NOTARY_PROFILE` | `cc-dashboard-notary` | Name of the keychain profile containing the ASC API key. |
| `APPLE_API_KEY_PATH` · `APPLE_API_KEY_ID` · `APPLE_API_ISSUER` | *(unset)* | CI path — use these instead of `CC_NOTARY_PROFILE` when the `.p8` is a file on disk. |

## Sparkle appcast

Each released DMG needs an `<item>` added to `docs/appcast.xml` with an
EdDSA signature. `scripts/update_appcast.sh` handles this — the release
workflow calls it automatically. Locally:

```bash
./scripts/update_appcast.sh dist/cc-dashboard.dmg
# requires swift package resolve + EdDSA keys in keychain via generate_keys
```
