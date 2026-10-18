# call-a-friend

Run heavy builds on your other machine while you keep working on the laptop.

```
caf run -- tools/bazel run //common:kernel_aarch64_dist
```

0. **Login check.** If Tailscale wants a login and there's no terminal to show its link on (for example when Claude runs caf), caf exits with status 76 instead of hanging. You then log in yourself by connecting once (`ssh <host> true`).
1. **Busy check.** caf checks the friend's load and free RAM. If the friend is busy, it shows the biggest processes and asks which ones to kill. Without a terminal to ask on, it exits with status 75.
2. **Push.** The project is rsynced to `~/.cache/call-a-friend/<project>-<hash>` on the friend. Files ignored by `.gitignore` or `exclude=` are skipped, and the friend's own build outputs are kept, so incremental builds still work.
3. **Run.** The command runs there. Output streams back with remote paths rewritten to local ones. If you hang up (Ctrl-C, the job is killed, the connection drops), the remote command is stopped too.
4. **Pull.** Files matching `pull=` are copied back.

The friend only holds the code in transit. Copies from before a reboot, or unused for `ttl_days`, are deleted on the next call. `caf clean` deletes one immediately.

## Setup

- On both machines: `rsync`.
- On the friend: key-based ssh access (Tailscale works).
- The toolchain must be installed on the friend, unless it ships inside the tree, as it does in Android kernel checkouts.

```sh
ln -s "$PWD/bin/caf" ~/.local/bin/caf             # manual use
mkdir -p ~/.config/call-a-friend
echo 'host=desktop' > ~/.config/call-a-friend/config
```

In each project, add a `.caf` file at the root. It marks what gets synced. For an Android kernel tree:

```
exclude=/out/
exclude=/.repo/
pull=/out/*/dist/**
```

Run `caf --help` for every key and command.

## Claude Code plugin

```
/plugin marketplace add /path/to/call-a-friend
/plugin install call-a-friend@call-a-friend
```

The plugin puts `caf` on Claude's PATH and adds a skill. The skill tells Claude to run heavy builds in the background through caf, and to ask you before killing anything on a busy friend.

## Test

`./test.sh` runs every command against a fake local friend.
