# Contributing to SpectiX

Thanks for helping. A few rules keep the project manageable.

## Build

Requirements: macOS 13+ and the Xcode Command Line Tools.

```bash
./tools/setup-signing-cert.sh   # one time: stable self-signed identity, so Accessibility survives rebuilds
./build.sh && pkill -x SpectiX; open "SpectiX Dev.app"
```

`./build.sh` produces `SpectiX Dev.app` with its own bundle id (`app.spectix.SpectiX.dev`), so it does not collide with an installed release build. `DEV_BUILD=0 ./build.sh` compiles the release configuration.

## Docs

Engineering docs live in [`docs/`](docs/). They are written in Chinese; machine translation works fine. Each one records pitfalls already hit in that area — read the one for the module you are changing before you change it. Start with [`docs/session-status.md`](docs/session-status.md) for anything status-related.

## The no-network rule is non-negotiable

The app binary must never open a network connection. `build.sh` refuses to compile networking APIs and refuses to link network libraries — do not work around those gates. **PRs that add networking to the app binary will be closed.**

If a feature truly needs the network, the only accepted pattern is **out of process and opt-in**: a separate process (a hook script, or a child process such as `/usr/bin/curl` spawned by the app) that runs only when the user explicitly asks for it, documented before it ships.

## UI changes

Include before/after screenshots in the PR. The scripts in `tools/` render parts of the UI offscreen to PNG, without needing screen capture or a running app:

- `tools/row-preview.sh` — session list rows (themes × light/dark × widths)
- `tools/header-preview.sh` — header metric columns
- `tools/panel-preview.sh` — stats panel
- `tools/capsule-preview.sh` — menu bar capsule

Check both the light and the dark output.

## Sign off your commits (DCO)

Every commit must carry a `Signed-off-by` line: use `git commit -s`.
By signing off you certify the [Developer Certificate of Origin](https://developercertificate.org/): you wrote the change, or otherwise have the right to submit it
under the project's open-source license (GPL-3.0), and you understand that the contribution and your sign-off are recorded publicly.

## Keep PRs focused

One change per PR. Unrelated refactors, formatting sweeps, and drive-by fixes go in separate PRs.
