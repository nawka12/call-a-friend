#!/usr/bin/env bash
# End-to-end check of bin/caf against a fake friend: a stub "ssh" runs the remote
# side locally, in its own session, with HOME=$T/friend. Needs rsync.
set -euo pipefail
caf=$(cd "$(dirname "$0")" && pwd)/bin/caf
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bin" "$T/friend" "$T/cfg/call-a-friend" "$T/proj"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
while [[ \$1 == -* ]]; do [[ \$1 == -o ]] && shift; shift; done
shift
[[ -e "$T/login" ]] && { echo '# Tailscale SSH requires an additional check.' >&2; echo '# To authenticate, visit: https://login.example/a/1' >&2; exec sleep 30; }
cd "$T/friend" && HOME="$T/friend" exec setsid sh -c "\$*"
EOF
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg"
echo 'host=fake' > "$T/cfg/call-a-friend/config"
cd "$T/proj"
printf 'exclude=/out/\npull=/out/**   # artifacts\nmirror=../tc\n' > .caf
mkdir -p "$T/tc" && echo clang > "$T/tc/clang"
echo '*.o' > .gitignore
echo 'int main;' > src.c
touch local.o
mkdir -p "$T/friend/.cache/call-a-friend/stale-1"
echo old-boot > "$T/friend/.cache/call-a-friend/stale-1.boot"

# push, path mapping, exit status, pull, pruning a copy from an earlier boot
rc=0
out=$("$caf" run -f -- 'ls; echo "$PWD/src.c:1: error"; mkdir -p out; echo built > out/bin; exit 3' 2>&1) || rc=$?
[[ $rc == 3 ]] || fail "exit status $rc: $out"
[[ $out == *"$T/proj/src.c:1: error"* ]] || fail "path not mapped: $out"
[[ $out != *local.o* ]] || fail "gitignored file was pushed: $out"
[[ $(cat out/bin) == built ]] || fail "artifact not pulled"
[[ $out == *"caf: pushed $T/tc in "* && $out == *"caf: pushed $T/proj in "* ]] || fail "no push summaries: $out"
[[ $out == *"caf: pulled artifacts in "*" (1 file, sent "* ]] || fail "no pull summary: $out"
[[ ! -e $T/friend/.cache/call-a-friend/stale-1 ]] || fail "stale copy not pruned"

# --delete mirrors local deletions but keeps the friend's ignored build outputs
ws=$(echo "$T"/friend/.cache/call-a-friend/proj-*/)
touch "$ws/built.o"
rm src.c
"$caf" run -f -- true 2> /dev/null
[[ ! -e $ws/src.c ]] || fail "deleted file still on the friend"
[[ -e $ws/built.o ]] || fail "friend's ignored file was deleted"

# a busy friend gives 75 when nobody can answer a prompt
echo 'min_mem_gb=999999' >> .caf
rc=0
"$caf" run -- true < /dev/null 2> /dev/null || rc=$?
[[ $rc == 75 ]] || fail "busy friend gave $rc"
"$caf" status | grep -q '^busy: ' || fail "status doesn't report busy"
sed -i '/min_mem_gb/d' .caf

# a pending Tailscale login is reported without its link instead of hanging
touch "$T/login"
rc=0
err=$(timeout 10 "$caf" status 2>&1 > /dev/null) || rc=$?
[[ $rc == 76 ]] || fail "pending login gave $rc: $err"
[[ $err != *https://* ]] || fail "login link leaked: $err"
rm "$T/login"

# hanging up stops the remote command
set -m
"$caf" run -f -- 'sleep 2; touch too-late' > /dev/null 2>&1 &
sleep 1
kill -TERM -- -$!
sleep 2
[[ ! -e $ws/too-late ]] || fail "remote command survived the hang-up"

"$caf" clean
[[ ! -e $ws ]] || fail "clean left the copy"
echo ok
