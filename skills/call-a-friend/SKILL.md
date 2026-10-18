---
name: call-a-friend
description: Run heavy commands (kernel and Android builds, LTO/ThinLTO links, big compiles, long test suites) on the user's stronger machine with `caf run` instead of this laptop, and keep doing light work locally meanwhile. Use when a build would be slow or memory-hungry here, or when the user mentions their desktop, the friend, or a remote build.
---

# Call a friend

`caf` (on PATH) copies the project to the friend, runs a command there and streams the output back. Run `caf --help` for the full reference.

## Before the first run

- The friend's host comes from `~/.config/call-a-friend/config` (`host=<ssh host>`). If that file is missing, ask the user for the host. Don't guess it.
- The project root is marked by a `.caf` file. If there isn't one, propose a `.caf` to the user and write it once they agree. It should exclude big outputs and caches, and pull back only the artifacts the user needs. Android kernel example (run from the repo root):

  ```
  exclude=/out/
  exclude=/.repo/
  pull=/out/*/dist/**
  ```

## Running

- Use `caf run -- <command>` from anywhere inside the project. The command runs from the project root on the friend, under bash.
- For anything longer than about a minute, call Bash with `run_in_background: true` and keep working on light local tasks. You'll be notified when it exits; then read the output.
- The project is pushed when the run starts. Edits made during the run reach the friend on the next run.
- Paths in the output are already mapped to local paths, so edit the files they name directly.
- Files matching `pull=` are copied back after the run, even if it failed.
- Keep quick commands, git, and anything that needs local devices (adb, fastboot) on the laptop.

## When the friend is busy (exit status 75)

`caf` prints the friend's load, free RAM and biggest processes, then stops without running anything. Never kill anything on your own.

1. Ask the user with AskUserQuestion (multiSelect). Offer one option per heavy process (for example "Kill python webui.py (PID 1234, 9.8G)"), plus "Run anyway".
2. If they picked processes, run `caf kill <pid...>`. If that fails with a permission error, tell the user. The process is probably a system service they need to stop themselves.
3. Rerun with `caf run -f -- <command>`. The load average lags for about a minute after a kill, so skip the check.

If the user declines everything, don't run.

## Other commands

- `caf status` shows the friend's load, RAM and top processes.
- `caf clean` deletes this project's copy on the friend. Copies are also deleted on their own after a reboot of the friend or `ttl_days` of no use.
