# Security Policy

## Reporting a vulnerability

Please report security issues privately by email to **hello@spectix.app**. Do not open a public issue.

Include the SpectiX version, macOS version, and steps to reproduce.

## High-value areas

- **Accessibility permission.** SpectiX holds Accessibility access to raise windows, locate terminal panes, and read window titles. Anything that lets another process steer those actions is in scope.
- **State files.** The app reads plain-text files that hooks write under `~/.claude/spectix/`, plus Claude Code's own state files. Parsing or path handling that can be abused through crafted file contents is in scope.
- **Credentials.** The account panel stores copies of Claude Code / Codex CLI sign-in credentials in the macOS Keychain and writes them back when you switch accounts. `CredentialVault.swift` is the only file that touches secrets; review there first.
- **The no-network guarantee.** Any way to make the app binary open a network connection, or to make the opt-in `curl` requests send more than documented, is a security bug.
