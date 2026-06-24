# OhDelhi auto-update (Sparkle) — one-time setup

Goal: OhDelhi on MMUtil (and the laptop) updates itself from **GitHub Releases**, silently in the background. After this is set up, shipping a new version is just `./release/release.sh 0.3 4`.

The Swift code is already in place (`Updater.swift` + the `SPUStandardUpdaterController` in `OhDelhiApp.swift`). What's left is the package, the keys, the Info.plist, the GitHub repo, and filling in the script. Work top to bottom.

---

## 1. Put OhDelhi on GitHub

OhDelhi isn't a git repo yet. From the project root:

```
cd ~/Developer/OhDelhi
git init
printf "build/\n*.xcuserstate\nDerivedData/\n" >> .gitignore
git add .
git commit -m "OhDelhi 0.2"
gh repo create OhDelhi --private --source=. --push
```

(Install `gh` first if needed: `brew install gh && gh auth login`.) Note the resulting `USER/OhDelhi` slug — you'll paste it in two places below.

## 2. Add Sparkle (Swift Package Manager)

In Xcode: **File ▸ Add Package Dependencies…** → URL `https://github.com/sparkle-project/Sparkle` → Dependency Rule "Up to Next Major" from **2.0.0** → add the **Sparkle** library to the **OhDelhi** (Mac) target.

That makes `import Sparkle` resolve, so `Updater.swift` and `OhDelhiApp.swift` compile.

## 3. Generate the EdDSA signing keys

Sparkle ships command-line tools (`generate_keys`, `sign_update`). Easiest: download the Sparkle release tarball (the "Sparkle-2.x.x.tar.xz" on the GitHub releases page), unpack, and you'll find them in `bin/`. Copy `sign_update` somewhere stable, e.g. `~/bin/sign_update` (the path `release.sh` defaults to).

```
./bin/generate_keys
```

- It stores the **private** key in your login keychain (never commit it).
- It prints the **public** key (a base64 string) — copy it; it goes in the Info.plist next.

## 4. Info.plist keys (silent auto-update)

Add these to the **OhDelhi** target's Info (Target ▸ **Info** tab ▸ *Custom macOS Application Target Properties* ▸ + ; if the target uses a generated Info.plist and won't take custom keys there, create an `Info.plist`, set `INFOPLIST_FILE` to it, and add them there):

| Key | Type | Value |
|-----|------|-------|
| `SUFeedURL` | String | `https://raw.githubusercontent.com/USER/OhDelhi/main/release/appcast.xml` |
| `SUPublicEDKey` | String | *(the public key from step 3)* |
| `SUEnableAutomaticChecks` | Boolean | `YES` |
| `SUAutomaticallyUpdate` | Boolean | `YES` ← download + install silently |
| `SUScheduledCheckInterval` | Number | `3600` (seconds; hourly) |

Replace `USER` with your GitHub username. `SUAutomaticallyUpdate = YES` is what makes MMUtil update without prompting.

> Sparkle requires the app **not** be sandboxed — OhDelhi's App Sandbox is already off, and Hardened Runtime (which it needs) is on. Good.

## 5. notarytool credentials

If you haven't already stored a notarytool profile (you've been notarising, so maybe), create one:

```
xcrun notarytool store-credentials "ohdelhi-notary" \
  --apple-id "your@appleid" --team-id "TEAMID" --password "app-specific-password"
```

The profile name must match `NOTARY_PROFILE` in `release.sh`.

## 6. Fill in the config

- `release/ExportOptions.plist` → set `REPLACE_TEAM_ID` to your 10-char Team ID.
- `release/release.sh` → set `GITHUB_REPO` (`USER/OhDelhi`), confirm `NOTARY_PROFILE`, `MIN_MACOS` (match your deployment target), and `SPARKLE_SIGN` (path to `sign_update`).
- `chmod +x release/release.sh`

## 7. Ship a release

```
./release/release.sh 0.2 3
```

It archives → notarises → staples → Sparkle-signs → prepends to `appcast.xml` → creates GitHub release `v0.2` with the zip → commits + pushes the appcast.

## 8. First-time install + test

- Build a 0.2 with the Sparkle keys in place and copy it to `/Applications` on MMUtil once **by hand** (the auto-updater can't bootstrap itself onto a machine that doesn't have a Sparkle-aware build yet).
- Then ship a **0.3** with `release.sh`. Within `SUScheduledCheckInterval`, MMUtil should download and silently update to 0.3, relaunching itself. (Or test immediately with the **Check for Updates…** item now in the app menu.)

After this, the deploy-to-MMUtil dance is gone: bump the version, run `release.sh`, and the box updates itself.
