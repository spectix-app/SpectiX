# Contributing to SpectiX

**SpectiX is source-available, but not open to code contributions.** Pull requests are closed without review. This keeps the code under a single author, so the project can change direction quickly.

What helps, and is very welcome:

- **Bug reports**: [open an issue](https://github.com/spectix-app/SpectiX/issues/new/choose) with your macOS version, terminal / editor, and what you saw.
- **Feature ideas and feedback**: open an issue. Good ideas get built, and the issue is credited in the changelog.
- **Security issues**: report them privately, see [SECURITY.md](SECURITY.md).

You may fork and modify it under the [FSL-1.1-ALv2](LICENSE): use it free, personally or at work, but do not sell it or ship a competing product built from it. Every release becomes Apache-2.0 two years after it ships. Please rename and rebrand a modified version you distribute.

## Building from source

Requirements: macOS 13+ and the Xcode Command Line Tools.

```bash
./tools/setup-signing-cert.sh   # one time: stable self-signed identity, so Accessibility survives rebuilds
./build.sh && pkill -x SpectiX; open "SpectiX Dev.app"
```

`./build.sh` produces `SpectiX Dev.app` with its own bundle id (`app.spectix.SpectiX.dev`), so it does not collide with an installed release build. `DEV_BUILD=0 ./build.sh` compiles the release configuration.

Engineering docs live in [`docs/`](docs/). They are written in Chinese; machine translation works fine. Start with [`docs/session-status.md`](docs/session-status.md) for anything status-related.

## The no-network rule

The app binary never opens a network connection. `build.sh` refuses to compile networking APIs and refuses to link network libraries. Anything that needs the network runs out of process (a hook script, or `/usr/bin/curl` spawned by the app) and only when the user explicitly asks for it.
