# Prior art: offloading builds from a laptop to another machine

Research date: 2026-10-18.

## Verdict

**We are not the first** to do "sync the project to a stronger machine, run the command there, sync the results back". That pattern goes back to at least 2016 (mainframer). Two Claude Code tools already exist too, and both send **every** Bash command to a remote host.

What I found **no one doing** is the combination we want:

1. **Selective offload.** Only heavy commands go to the desktop. Everything else (git, grep, quick tests) stays on the laptop.
2. **Asynchronous by default.** The build runs on the desktop while Claude keeps doing light work on the laptop, and it gets notified when the build finishes.
3. **One tool for both cases.** The same CLI works by hand and as a Claude Code plugin.
4. **Linux laptop.** The closest Claude Code tool, langwatch/claude-remote, is tested on macOS only.
5. **Pull back only what you need.** For a kernel build, that means `Image`/`boot.img`, not a multi-GB `out/` directory.

## Closest relatives

### Generic "sync, run, sync back" CLIs

| Tool | Approach | What to take from it |
|---|---|---|
| [mainframer](https://github.com/buildfoundation/mainframer) (2.x stable, 3.x Rust rewrite in progress) | rsync push → ssh exec → rsync pull | **Separate ignore rules for push and pull** (`push:` skips build outputs, `pull:` skips sources, `both:` skips `.git`/IDE files). rsync compression level as a config knob. A `parallel` pull mode that pulls *while* the build runs. Project config in `.mainframer/config.yml`, which holds the host and is not committed, and `ignore.yml`, which is committed. |
| [remote-cli/remote](https://github.com/remote-cli/remote) | rsync + ssh, Python | A global config merged with a per-workspace config. **Several hosts with labels** (`-l desktop`). A `.remoteenv` file sourced on the remote before each command, for toolchain PATH and envsetup. `remote-quick` runs without syncing. `remote-explain` prints the resolved command. An option to reuse `.gitignore` patterns as excludes. `remote-pull <dir>` fetches a directory on demand even if it is ignored. |
| [rsync_cmd](https://github.com/ltratt/rsync_cmd) | rsync + ssh | **A marker file as a safety guard.** It only syncs directories that contain a `.rsync_cmd` file, so it can't accidentally `rsync --delete` your `$HOME`. |
| [outrun](https://pypi.org/project/outrun/) | FUSE-mounts the local filesystem on the remote and chroots into it, so no toolchain is needed remotely | **Rejected for us.** It needs root on the remote, and every file access is a network round trip, which is bad for a kernel tree with tens of thousands of files. The idea "the remote doesn't need the toolchain" is still worth remembering. |
| [LiveSync](https://github.com/zauberzeug/livesync), [Mutagen](https://mutagen.io/) | Continuous file watching and sync | Mutagen gives real bidirectional sync with low latency on every change. It is the alternative to running rsync once per command. |

### Claude Code-specific

| Tool | Approach | What to take from it |
|---|---|---|
| [torarnv/claude-remote-shell](https://github.com/torarnv/claude-remote-shell) | Sets `CLAUDE_CODE_SHELL` to a wrapper, so **every** Bash tool call runs over ssh. Optional Mutagen sync, flushed before and after each command. | **Rewrite paths in both directions** (local→remote in the command, remote→local in the output) so compiler errors point at files Claude can edit locally. Pitfall: a git worktree's `.git` file contains an absolute `gitdir:` path, which is wrong on the remote. |
| [langwatch/claude-remote](https://github.com/langwatch/claude-remote) | A `$SHELL` wrapper with an on/off toggle. Inspired the tool above. macOS only. | **Reachability check with a 2 s timeout** before each command. **Fail-safe mode parsing**: anything other than exactly `on` runs locally. **Toggle state lives in files** because Claude re-execs the shell for every Bash call, so environment variables don't persist. **ssh ControlMaster** for fast repeated connections, plus a fix for **stale control sockets after a VPN reconnect** (this matters for Tailscale). **`PATH_IDENTITY` mode**: the project lives at the same absolute path on the remote, which removes the need for path rewriting. |
| SSH MCP servers ([tufantunc/ssh-mcp](https://github.com/tufantunc/ssh-mcp), [overklassniy/ssh-mcp](https://github.com/overklassniy/ssh-mcp), …) | Remote command execution as MCP tools | No source sync, so they are generic remote shells. Useful idea: allow/deny command regexes. An MCP server isn't needed for our case. A CLI plus a skill (and optionally a hook) is simpler and also works without Claude. |
| Claude Desktop [SSH remote sessions](https://claude.com/docs/third-party/claude-desktop/ssh-remote-sessions) | Runs the **whole** Claude Code engine on the remote | Wrong shape for us: Claude would run on the desktop, not the laptop. Also, plugin hooks are not copied to the remote. |

### Distributed compilers: they don't solve the ThinLTO problem

[distcc](https://www.distcc.org/), [icecream](https://github.com/icecc/icecream), [sccache-dist](https://github.com/mozilla/sccache/blob/main/docs/Distributed.md) and Goma/reclient send *individual compile units* to other machines. The **link step, which is where ThinLTO happens, still runs locally**, and that step is where the laptop runs out of memory. Distributed ThinLTO does exist ([Sony's icecream work](https://llvm.org/devmtg/2021-11/slides/2021-Distributed-ThinLTO-With-Icecream.pdf), [LLVM DTLTO](https://rocm.docs.amd.com/projects/llvm-project/en/develop/LLVM/llvm/html/DTLTO.html), and an [RFC for the kernel](https://discourse.llvm.org/t/rfc-distributed-thinlto-build-for-kernel/85934)), but it is complex, toolchain-specific and not something we can rely on. **Running the whole build remotely is the right model.**

### Domain-specific and heavyweight options (noted, not copied)

- **Bazel remote execution** (Buildbarn, BuildBuddy, NativeLink). Android **Kleaf** (Bazel-based GKI kernel builds) can in theory use it. That would mean running a Buildbarn cluster on the desktop, which is heavy, and it only helps Bazel projects.
- **Nix remote builders** (`builders = ssh://desktop`), **Gradle Mirakle**, `DOCKER_HOST=ssh://`. Each is a good fit inside its own ecosystem and useless outside it.
- **Commercial**: Incredibuild, Depot, Earthly Satellites.

## Design notes for call-a-friend (based on the above)

- **Core = one CLI** (for example `caf run -- make -j32`). This is the manual mode. The Claude Code plugin is a thin layer on top:
  - A **skill** tells Claude when to call a friend: heavy builds, LTO links, anything above some memory threshold.
  - An optional **PreToolUse hook** rewrites Bash commands that match configured patterns (for example `build/build.sh`, `make.*LTO`, `tools/bazel`) into `caf run -- …` using `hookSpecificOutput.updatedInput`. That is selective, unlike redirecting the whole shell.
  - **Async comes almost for free.** Claude runs `caf run` with `run_in_background` and is notified when it exits. No daemon is needed.
- **Same absolute path on the desktop by default** (langwatch's `PATH_IDENTITY`). Compiler error paths, debug info and ccache keys then match without rewriting.
- **Separate push and pull rules** (mainframer). For kernels, pull only declared artifacts.
- **Safety:** a marker file / workspace config is required before syncing with `--delete` (rsync_cmd).
- **Reachability:** fast ssh check, ControlMaster with ControlPersist, and clean up stale sockets after Tailscale reconnects. **Do not silently fall back to local by default** (unlike langwatch). For an LTO kernel build, a local fallback is exactly the OOM we're avoiding. Fail loudly instead, and make fallback opt-in.
- **`.remoteenv`-style hook** for remote setup (toolchain PATH, `source build/envsetup.sh`).

## Open questions

1. **How to sync**: rsync per command (simple, but the first sync of a repo-managed kernel tree with prebuilts is many GB) **or** git-based (the desktop keeps its own `repo sync` checkout, and we ship only the uncommitted diff or a temporary commit, which is tiny per run)? A hybrid is possible: git for tracked files, rsync for untracked ones.
2. **Sharing the desktop with the diffusion server**: run builds under `nice`/`ionice`, or cap `-j`? The diffusion server is mostly GPU-bound, so CPU contention is probably fine, but RAM during an LTO link could compete with model weights in memory.
3. **Several friends** (labels like remote-cli) now, or one host only until it's needed?
