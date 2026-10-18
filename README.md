# call-a-friend

Your laptop can't link that LTO kernel, and your desktop at home sits idle. `caf` runs the build on the desktop and brings the result back, while you (or Claude Code) keep working on the laptop.

```
caf run -- make -j12 O=out
```

It works by hand and as a Claude Code plugin. It's a single bash script that talks to the other machine (the "friend") over plain ssh and rsync.

## How a run works

0. **Login check.** If Tailscale wants a login and there's no terminal to show its link on (for example when Claude runs caf), caf exits with status 76 instead of hanging. You then log in yourself by connecting once (`ssh <host> true`).
1. **Busy check.** caf checks the friend's load and free RAM. If the friend is busy, it shows the biggest processes and asks which ones to kill. Without a terminal to ask on, it exits with status 75.
2. **Push.** The project is rsynced to `~/.cache/call-a-friend/<project>-<hash>` on the friend. Files ignored by `.gitignore` or `exclude=` are skipped, and the friend's own build outputs are kept, so incremental builds still work.
3. **Run.** The command runs there. Output streams back with remote paths rewritten to local ones. If you hang up (Ctrl-C, the job is killed, the connection drops), the remote command is stopped too.
4. **Pull.** Files matching `pull=` are copied back.

The friend only holds the code in transit. Copies from before a reboot, or unused for `ttl_days`, are deleted on the next call. `caf clean` deletes one immediately.

## Install

You need:

- Linux on both machines (WSL2 counts). macOS and native Windows aren't supported.
- `rsync` on both machines.
- Key-based ssh from the laptop to the friend (OpenSSH or Tailscale SSH).
- The build's toolchain on the friend, unless it ships inside the tree, as in Android kernel checkouts, or you mirror it (see below).

**As a Claude Code plugin:**

```
/plugin marketplace add nawka12/call-a-friend
/plugin install call-a-friend@call-a-friend
```

The plugin puts `caf` on Claude's PATH and adds a skill. With it, Claude runs heavy builds in the background through caf and keeps working locally meanwhile. It asks you before killing anything on a busy friend.

**By hand:**

```sh
git clone https://github.com/nawka12/call-a-friend
ln -s "$PWD/call-a-friend/bin/caf" ~/.local/bin/caf
```

Either way, tell caf which machine to call (any name ssh accepts), then check the connection:

```sh
mkdir -p ~/.config/call-a-friend
echo 'host=desktop' > ~/.config/call-a-friend/config
caf status
```

## Configure a project

Add a `.caf` file at the project root. It marks what gets synced. For an Android kernel tree:

```
exclude=/out/
exclude=/.repo/
pull=/out/*/dist/**
```

If the build needs a folder outside the project, such as a toolchain beside it, add `mirror=../toolchain`. caf pushes it to the same absolute path on the friend, so hard-coded paths in build scripts keep working. Mirrors are the one exception to "transit only": they stay on the friend, and caf only adds or updates files in them, never deletes.

### Mirrors

A mirror needs the same absolute path on the friend, writable by the ssh user. If your username differs there (`/home/you` on the laptop, `/home/them` on the friend), the push fails before anything runs. To fix it, do one of these:

- Log in as the same user: `host=you@desktop`, or `User` in `~/.ssh/config`.
- Have root on the friend link the path once: `sudo ln -s /home/them /home/you`.
- Keep the folder at a path that exists on both machines, such as `/opt/toolchains`.

Run `caf --help` for every key.

## Commands

| Command | What it does |
|---|---|
| `caf run [-f] -- <command>` | Push, run, pull. `-f` skips the busy check. |
| `caf status` | The friend's load, free RAM and biggest processes, and whether Tailscale is direct or relayed. |
| `caf kill <pid...>` | Send SIGTERM to processes on the friend. |
| `caf clean` | Delete this project's copy on the friend. |

`caf run` exits with the command's own status, 75 when the friend is busy, or 76 when Tailscale wants a login.

## Limitations

- One friend at a time.
- The build stops if the connection drops. There's no detached mode yet.
- The busy check's per-process CPU figure is each process's lifetime average. The busy decision itself uses the 1-minute load average.

[RESEARCH.md](RESEARCH.md) compares caf with similar tools (mainframer, remote-cli, distcc and others).

## Test

`./test.sh` runs every command against a fake local friend.

## License

[MIT](LICENSE)
