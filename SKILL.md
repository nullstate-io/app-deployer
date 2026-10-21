---
name: app-deployer
description: App Deployer by nullstate. Turns a local app (a Python web server with a native launcher, a native Swift app, or a Node server) into a private, self-contained, drag-to-Applications macOS DMG plus a user guide, with every dependency bundled and no source code shipped. Use when asked to make a standalone, self-contained, portable or offline Mac build, "package this app as a DMG", "make it run on another Mac", "bundle the dependencies", "ship it without the source", or to prepare a private internal deployment for other Macs. Not for review or handoff bundles (screenshots, zips for a reviewer); this skill produces an installable product.
---

# App Deployer by nullstate

Produce two deliverables: `<App>.dmg` (only the .app and an Applications link) and `<App> Guide.html`. The dev build stays untouched; every standalone behavior hangs off one env flag the launcher sets.

Scripts live in `scripts/` next to this file. Run any of them with `-h` for usage.

| Script | Job |
|---|---|
| `scan-secrets.sh <dir>` | secrets, home paths, tailnet hosts, LAN IPs, emails; non-zero on findings |
| `node-embed.sh` | pinned Node binary + production `node_modules` into Resources |
| `python-embed.sh` | relocatable Python + pinned deps into Resources/python |
| `python-strip-source.sh` | compile to sourceless .pyc, delete .py |
| `bundle-dylibs.sh` | relocate a binary's Homebrew dylib closure into Contents/Frameworks |
| `sign.sh --app <.app>` | inside-out signing, Developer ID if present else ad hoc |
| `make-dmg.sh --app <.app> --out <.dmg>` | staging, image, read-only verification |
| `verify-clean.sh --dmg <.dmg> --health-path /api/...` | clean-machine simulation and evidence log |

## Inputs to settle first

Decide these without asking when the repo makes them clear; write them at the top of the build script.

- App name (display name; may contain spaces, so quote every path) and bundle id (`com.<owner>.<app>`).
- Data dir: `~/Library/Application Support/<App>/` (logs in `.../<App>/logs/`, caches in `~/Library/Caches/<bundle id>/`).
- Port policy: loopback only, a free port picked at launch from a fixed range (default 4700-4800), never the dev build's port, so both can run at once.
- Minimum macOS (`LSMinimumSystemVersion`) and arch: `arm64` unless the owner needs Intel; universal only if every bundled binary is universal (check with `lipo -archs`).
- Version: read from the repo's `VERSION` (or package metadata) into `CFBundleShortVersionString`.

## 1 Dependency inventory

Enumerate everything the app touches at runtime, then decide each one.

- Python: `pip freeze` (or `uv pip freeze`) from the dev venv; cross-check with what is actually imported: run the app plus one real job under `python -X importtime` or with `sys.modules` dumped at exit. Drop dev, test and lint packages and heavy packages nothing imports.
- Native binaries and extension modules: `otool -L` on each, recursively (the closure). Anything under `/opt/homebrew`, `/usr/local` or a user path must be bundled or replaced; `/usr/lib` and `/System` are fine.
- Models and caches: `~/.cache/huggingface`, `~/.cache/torch`, `~/Library/Caches/*`, model paths in config. Note size and license of each.
- Node: `package.json` dependencies vs devDependencies; native addons (`find node_modules -name '*.node'`).
- External CLIs: grep for `subprocess`, `shutil.which`, `Popen`, `execFile`, `spawn`, `Process()`; each resolves via PATH today and will not on a clean Mac.
- Hardcoded paths: `grep -rnE '/Users/|/opt/homebrew|/usr/local|expanduser|~/' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv .`
- Sibling apps and services the app calls (other local servers, launch agents).

Produce a table: `dependency | where found | size | bundle / replace / drop | note`. Every row needs a decision before building.

## 2 Private services and secrets

Grep checklist (run `scripts/scan-secrets.sh <repo>` too):

- tokens, API keys, `.env*`, `config.json` with credentials, cookies, keychain lookups
- VPN or tailnet hostnames, LAN IPs, remote pairing or relay endpoints, proxies
- launch agents, login items, cron, `launchctl` calls
- telemetry, crash reporters, update checks, analytics
- integrations with sibling apps (posting to another local server, shared folders)

For each feature decide one of: **keep-local** (works offline as-is), **optional-off** (disabled by default, an in-app note says what it needs and how to enable it), **remove** (code path unreachable in standalone). Record the list; it goes in the report.

Rules:

- Gate every change behind one flag (e.g. `APP_STANDALONE=1`) that only the launcher sets. The dev build never sees it.
- Bind `127.0.0.1` only. Refuse forwarded and proxy headers (`X-Forwarded-*`, `Forwarded`, `X-Real-IP`) and reject requests whose `Host` is not loopback.
- No secret, token or owner-specific default ships in the bundle. Settings that need one start empty.

## 3 Bundle layout and launcher

```
<App>.app/Contents/
  Info.plist
  MacOS/<launcher>              native launcher (Swift/ObjC), the only thing in MacOS
  Resources/
    python/                     bundled runtime (or node/)
    app/                        compiled app code, no source
    static/                     web assets
    bin/                        bundled CLIs (ffmpeg ...)
    models/                     model files, symlinks resolved
    guide.html                  the user guide
  Frameworks/                   relocated dylibs
```

Launcher responsibilities:

- Set `APP_STANDALONE=1` and spawn the engine as a child with a clean env: `PATH=<Resources>/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `HOME` kept, `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `PYTHONNOUSERSITE=1`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONHOME` unset, data dir and port passed explicitly.
- Pick a free loopback port from the range; wait for the health endpoint with a timeout; show a readable error window (with the log path) if it never answers.
- Show the UI in a `WKWebView` pointed at `http://127.0.0.1:<port>/`.
- Kill the child on quit and on launcher death: the child watches its parent (stdin pipe EOF or `getppid()` change) and exits; the launcher also terminates the process group on `applicationWillTerminate`.
- Help menu opens the bundled `guide.html`.
- Writable data only in Application Support (and Caches); never write inside the .app.

## 4 Runtime bundling per stack

**Python**
- Runtime: python-build-standalone via `uv python install <version>` (relocatable); copy into `Resources/python` with `scripts/python-embed.sh` (usage: `-h`).
- Deps: `uv pip install --python <bundled python> --no-deps -r requirements.lock` where the lock is the dev freeze minus dev/test/unused heavy packages, versions pinned.
- Prune: `test/`, `tests/`, `idlelib`, `tkinter`, `turtledemo`, `ensurepip`, `lib2to3`, `__pycache__`, headers, static libs. `*.dist-info/RECORD` can stay.
- Models: copy with symlinks resolved (`cp -RL` or `rsync -L`); point the app at the bundled path, not the hub cache.

**Swift**
- `xcodebuild archive` (or `swift build -c release` and assemble the bundle by hand); embed frameworks under `Contents/Frameworks`; ship no dSYMs.
- Hardened Runtime is optional with ad hoc signing; required for notarization.

**Node**
- Copy a pinned official Node binary (from a local nvm install, or the nodejs.org tarball verified against `SHASUMS256.txt`) with `scripts/node-embed.sh`.
- `npm ci --omit=dev` in a copy of the app; optionally bundle with esbuild into one minified file; strip `.ts`, `.map`, `src/`, tests, docs.

**Binaries** (ffmpeg and similar)
- Prefer static builds. Otherwise `scripts/bundle-dylibs.sh` relocates the Homebrew dylib closure into `Contents/Frameworks` with `@rpath` / `@loader_path` and re-signs.
- Confirm with `otool -L`: no `/opt/homebrew`, `/usr/local` or user paths remain.

## 5 Strip source

- Python: `scripts/python-strip-source.sh` (compileall `-b`, legacy layout, so sourceless imports work; then delete `.py`). Some libraries read their own source (`inspect.getsource`, `torch.jit.script`); keep those files and list them as allowed.
- Delete `tests/`, docs, `.git`, review/handoff folders, `perf/`, `logs/`, lab or scratch folders, sample data, `*.map`, `*.ts`, editor configs.
- Minify web assets if a local minifier exists (esbuild, terser); never fetch one.
- Check: `find "$APP" -name '*.py'` prints nothing (except the documented allow list).

## 6 Signing

- `security find-identity -v -p codesigning`. Use "Developer ID Application" if present, else ad hoc (`codesign --force -s -`).
- Sign inside-out: dylibs and `.so`, executables, nested bundles and frameworks, then the app. `scripts/sign.sh` does this. Never rely on `--deep` for signing.
- Hardened Runtime with Python usually needs entitlements on the interpreter: `com.apple.security.cs.disable-library-validation` and often `com.apple.security.cs.allow-unsigned-executable-memory`. Pass them with `--entitlements` (applied to every executable and the app). Ad hoc plus `--runtime` plus disable-library-validation loads bundled dylibs fine.
- Verify: `codesign --verify --strict --deep --verbose=2 "$APP"`.
- Notarization needs the owner's Apple ID or notary credentials (a `notarytool` keychain profile). The agent never does it; document the Gatekeeper first-launch step instead, and give the owner the two commands (`xcrun notarytool submit <dmg> --keychain-profile <profile> --wait`, `xcrun stapler staple <dmg>`) if they want it.

## 7 DMG

- Contents: only the .app and an `/Applications` symlink. No loose files, no `.DS_Store`, no background art.
- `scripts/make-dmg.sh --app <.app> --out <.dmg> [--volname NAME] [--format UDZO|ULFO]`. UDZO opens everywhere; ULFO is smaller and needs 10.11+.
- It verifies by attaching with `-nobrowse -readonly` and listing.

## 8 Clean-machine verification

Run `scripts/verify-clean.sh --dmg <.dmg> --health-path /api/health --job-cmd '<real job using $PORT>'`. It covers:

- [ ] mount the DMG; it holds exactly the app and the Applications link
- [ ] copy the app to a scratch dir; launch the executable with `env -i HOME=<empty dir> PATH=/usr/bin:/bin:/usr/sbin:/sbin`
- [ ] the engine answers the health path on a loopback port in the range; no listener on `*` or a LAN address
- [ ] one real end-to-end job succeeds (`--job-cmd`, e.g. upload a sample file and poll for the result)
- [ ] connections of the whole process tree (`lsof -i -nP`, sampled through the run) show no non-loopback or forbidden host/port
- [ ] no forbidden strings in the bundle (home paths, hostnames, tokens; add a `--forbid-file`)
- [ ] no source files (`*.py`, `*.ts`, `*.map`, `.git`)
- [ ] every Mach-O links only to `/usr/lib`, `/System` or bundle-relative paths
- [ ] `codesign --verify --strict --deep` passes
- [ ] every Mach-O has the target arch
- [ ] the child processes exit when the launcher is terminated
- [ ] app and DMG sizes recorded

Only a second Mac can confirm: the Gatekeeper quarantine flow and app translocation, keychain prompts, TCC prompts (camera, microphone, files, automation), first-run behavior with a real empty account. Say so in the report; never claim them.

## 9 User guide

One self-contained HTML file: inline CSS, fonts base64-embedded, no network requests, no scripts it does not need. Follow the owner's design system if one exists. Sections:

1. What it does (two or three sentences).
2. Install: open the DMG, drag the app to Applications, eject.
3. First launch: Gatekeeper will block an un-notarized app. Control-click the app, choose Open, then Open; or System Settings > Privacy & Security > Open Anyway.
4. Each feature and each setting, in the order the UI shows them.
5. Optional features: what each needs (an account, a key, another app) and how to turn it on.
6. Where data and logs live (`~/Library/Application Support/<App>/`).
7. Uninstall: quit, drag the app to the Trash, delete the data folder.
8. Troubleshooting table: symptom | cause | fix.
9. Reporting a bug: version (About menu), the log file, steps to reproduce, macOS version.

Ship it inside the bundle (`Resources/guide.html`, Help menu) and beside the DMG.

## 10 Report

```
DMG:        <path>  <size>  <arch>  macOS <min>+
Guide:      <path>
Version:    <version>  bundle id <id>
Signing:    Developer ID <team> | ad hoc (Gatekeeper will prompt); notarized: no
Clean run:  verify-clean PASS, log <path>; health <ms>; job <what ran, result>
Network:    loopback only (lsof samples: <n>) | <exceptions>
Features:   <feature>: keep-local | optional-off (<what it needs>) | removed
Not verified (needs a second Mac): Gatekeeper/translocation, keychain, TCC prompts
Known limits: <anything else>
```

## Pitfalls

- Ad hoc signatures change on every build, so TCC and keychain grants re-prompt after each update. A Developer ID keeps them.
- Never write into the .app: it breaks the signature and fails under translocation (read-only).
- Finder-launched apps get a minimal PATH and no shell profile; resolve every tool to a bundled path.
- The Hugging Face hub tries the network unless `HF_HUB_OFFLINE=1` and models load from local paths.
- PyObjC, mlx, numpy and every other `.so` must be signed individually, or library validation kills the process.
- Spaces in app names break unquoted shell; quote every path.
- Gatekeeper translocation runs quarantined apps from a random read-only path; never derive data paths from the bundle location.
- Python-build-standalone files can be read-only; `chmod -R u+w` before signing or pruning.
- A `.bundle` directory in a Python package is often a resource folder, not code; only directories with an Info.plist get signed as bundles.
- Prune by evidence, not by name: a heavy package that looks unused can be a hard import of a kept one (coremltools imports sympy at import time). After pruning, import every kept top-level package with the bundled interpreter in a clean env before going further.
- uv writes its install prefix (inside the builder's home) into `_sysconfigdata` and libpython's install name, and wheels carry their CI's absolute LC_RPATHs; `python-embed.sh` rewrites and drops them. Bytecode records the path it was compiled at unless compileall gets `-s/-p` (`python-strip-source.sh` does). The string scan will still find upstream CI paths (the CI runner's home directory) inside third-party binaries: allow-list those by name, never your own.
- `otool -L` on a universal binary prints one header line per arch; parse only the tab-indented dependency lines, and skip a dylib's own install name.
- A python-build-standalone `python3` links libpython statically; check relocatability by "nothing outside /System and /usr/lib" in `otool -L`, not by looking for `@rpath`.
- Ship the tools a library finds on PATH at runtime: yt-dlp needs a JavaScript runtime (deno) for YouTube; bundle it with `bundle-dylibs.sh` and turn off its update check (`DENO_NO_UPDATE_CHECK=1`, `DENO_DIR` in the data folder).
- A library that self-updates (yt-dlp) can't write into the signed bundle: install updates with `pip install --target <data>/pylib --no-deps` and put that folder first on `sys.path`.
- The launcher must own the engine's lifetime: spawn it in its own process group (`POSIX_SPAWN_SETPGROUP`), stop the group on quit, respawn with a throttle, and have the engine exit on its own when its parent changes.
- Fork the dev launcher rather than `#ifdef`-ing it when the dev build carries features the standalone drops (remote modes, launch agents, widgets): the fork stays small and the dev file stays untouched.
