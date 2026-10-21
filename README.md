# App Deployer by nullstate

A Claude Code skill that turns a local app (a Python web server with a native launcher, a native Swift app, or a Node server) into a private, self-contained, drag-to-Applications macOS DMG plus a user guide. Every dependency is bundled, no source code ships, and the result is checked on the build Mac in a simulated clean environment.

It is not a review or handoff bundler; it produces an installable product for other Macs.

## Install

```sh
git clone https://github.com/nullstate-io/app-deployer ~/.claude/skills/app-deployer
```

Claude Code picks it up on the next session. Ask for a "standalone DMG" of an app, or invoke it by name.

## Scripts

All in `scripts/`, bash, macOS tools only. Run any of them with `-h`.

| Script | Purpose |
|---|---|
| `scan-secrets.sh` | find keys, tokens, home paths, tailnet hosts, LAN IPs and emails in a tree (uses gitleaks too when installed) |
| `node-embed.sh` | copy a pinned Node binary and a production `npm ci` of the app into Resources; optional esbuild bundle |
| `python-embed.sh` | copy a relocatable Python and pinned dependencies into Resources |
| `python-strip-source.sh` | compile to sourceless `.pyc` and delete `.py` |
| `bundle-dylibs.sh` | relocate a binary's Homebrew dylib closure into `Contents/Frameworks` |
| `sign.sh` | sign a bundle inside-out with Developer ID, or ad hoc when none is present |
| `make-dmg.sh` | build a DMG holding only the app and an Applications link, then verify it |
| `verify-clean.sh` | mount the DMG, check the bundle, launch with an empty HOME and minimal PATH, run a job, watch the network, quit |

## Requirements

macOS with the Xcode command line tools (`codesign`, `hdiutil`, `otool`, `lipo`). `uv` for Python apps, `npm` for Node apps. Notarization is left to the app owner (it needs their Apple credentials).

## License

MIT
