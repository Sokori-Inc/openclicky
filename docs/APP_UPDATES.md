# OpenClicky App Updates

OpenClicky uses Sparkle 2 for direct-distribution updates. This does not apply to a future Mac App Store build, where updates must come through the App Store.

The app is configured for OTA-style updates:

- `SUEnableAutomaticChecks`: checks for updates automatically.
- `SUAllowsAutomaticUpdates`: allows the automatic update option.
- `SUAutomaticallyUpdate`: defaults to background download and install behavior.
- `SUScheduledCheckInterval`: checks roughly once per day.

## Update Feed

- Feed URL in the app: `https://raw.githubusercontent.com/jasonkneen/openclicky/main/appcast.xml`
- Feed file in this repo: `appcast.xml`
- Release asset host: GitHub Releases under `https://github.com/jasonkneen/openclicky/releases`
- Public EdDSA key in `Info.plist`: `SUPublicEDKey`

The checked-in `appcast.xml` is intentionally an empty OpenClicky feed until the first signed release artifact exists.

Before the first real OpenClicky release, confirm that you still have the Sparkle private key matching `SUPublicEDKey`. If not, generate a new Sparkle EdDSA key pair, replace `SUPublicEDKey` in `Info.plist` with the new public key, and keep the private key outside the repository. Existing installed builds can only move to a new Sparkle key if they first receive a bridge update signed by the old key.

## Release Flow

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Xcode.
2. Archive the app in Xcode with the `leanring-buddy` scheme.
3. Export a Developer ID signed app for direct distribution.
4. Package the exported `.app` into a DMG.
5. Notarize and staple the DMG.
6. Sign the DMG for Sparkle with Sparkle's `sign_update` tool.
7. Upload the stapled DMG to a GitHub Release named `v<MARKETING_VERSION>`.
8. Add a new item to `appcast.xml`.
9. Commit and push `appcast.xml` to `main`.

## Appcast Item Shape

Use this template after replacing the version, build, date, URL, byte length, and Sparkle signature:

```xml
<item>
    <title>OpenClicky 1.0.1</title>
    <pubDate>Fri, 24 Apr 2026 16:10:08 +0000</pubDate>
    <sparkle:version>7</sparkle:version>
    <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/jasonkneen/openclicky/releases/download/v1.0.1/OpenClicky-1.0.1.dmg"
        length="12345678"
        type="application/octet-stream"
        sparkle:edSignature="SIGNATURE_FROM_SPARKLE_SIGN_UPDATE"/>
</item>
```

## Local Commands

The exact Sparkle binary path depends on where Xcode stores Swift package artifacts. If the app archive contains Sparkle tools, use that `sign_update`; otherwise build or download Sparkle's release tools.

```sh
# Notarize the DMG. The keychain profile is created once with notarytool store-credentials.
xcrun notarytool submit OpenClicky-1.0.1.dmg --keychain-profile "openclicky-notary" --wait
xcrun stapler staple OpenClicky-1.0.1.dmg

# Generate Sparkle's EdDSA signature.
sign_update OpenClicky-1.0.1.dmg

# Get the byte length for the appcast enclosure.
stat -f%z OpenClicky-1.0.1.dmg
```

## Review Checklist

- The DMG opens without Gatekeeper warnings on a clean Mac.
- `spctl --assess --type open --context context:primary-signature -vv OpenClicky-1.0.1.dmg` accepts it.
- The appcast URL is reachable over HTTPS.
- The new appcast item has a higher `sparkle:version` than the installed build.
- The appcast item URL exactly matches the uploaded GitHub Release asset.
- `sparkle:edSignature` was generated from the final stapled DMG, not an earlier copy.
- A clean installed build checks the feed and offers or stages the update without sending the user to GitHub manually.
