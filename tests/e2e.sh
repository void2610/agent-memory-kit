#!/usr/bin/env bash
# agent-memory-kit の通しテスト。
# 偽の HOME とローカルの bare リポを使うので、実環境の ~/.claude やメモリには触れない。
#   使い方: tests/e2e.sh            （python3 を使用）
#           PYTHON=/usr/bin/python3 tests/e2e.sh
set -u

KIT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
S="$(mktemp -d "${TMPDIR:-/tmp}/amk-e2e.XXXXXX")"
S="$(cd "$S" && pwd -P)"
trap 'rm -rf "$S"' EXIT

export HOME="$S/home"
mkdir -p "$HOME/.claude"
unset XDG_CONFIG_HOME XDG_STATE_HOME CLAUDE_CONFIG_DIR AGENT_MEMORY_DIR AGENT_MEMORY_CONFIG \
      AGENT_MEMORY_STATE AGENT_MEMORY_TRANSCRIPTS AGENT_MEMORY_HOOKS
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

echo "python: $("$PY" --version 2>&1) ($PY)"
echo "git:    $(git --version)"

M() { "$PY" "$KIT/bin/mem" "$@"; }
pass=0; fail=0
ok() { echo "  PASS $1"; pass=$((pass + 1)); }
ng() { echo "  FAIL $1"; fail=$((fail + 1)); }
# chk <名前> <コマンド...> — コマンドが成功すれば PASS
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ng "$name"; fi; }
has() { printf '%s' "$1" | grep -q -- "$2"; }          # has <文字列> <パターン>
hasnt() { ! printf '%s' "$1" | grep -q -- "$2"; }
empty() { [ -z "$1" ]; }
infile() { grep -q -- "$2" "$1"; }                       # infile <ファイル> <パターン>
remote_log() { git --git-dir="$S/remote.git" log --oneline "${1:-main}"; }
remote_show() { git --git-dir="$S/remote.git" show "main:$1"; }
delline() { "$PY" - "$1" "$2" <<'EOF'
import sys
p, pat = sys.argv[1], sys.argv[2]
lines = open(p, encoding="utf-8").read().splitlines(True)
open(p, "w", encoding="utf-8").write("".join(l for l in lines if pat not in l))
EOF
}
subst() { "$PY" - "$1" "$2" "$3" <<'EOF'
import sys
p, a, b = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace(a, b))
EOF
}
waitsync() { local i=0; while [ $i -lt 120 ]; do pgrep -f "mem sync" >/dev/null 2>&1 || return 0; sleep 0.5; i=$((i + 1)); done; }
hook() { local ev="$1" json="$2"; printf '%s' "$json" | M hook "$ev"; }

git init -q --bare "$S/remote.git"
echo '{"permissions":{"allow":["Bash(npm test)"]}}' > "$HOME/.claude/settings.json"
MEMD="$HOME/agent-memory"

echo "== install"
LAUNCHD_FLAG=""
[ "$(uname)" = "Darwin" ] && LAUNCHD_FLAG="--launchd"
M install --remote "$S/remote.git" --disable-auto-memory $LAUNCHD_FLAG >/dev/null
chk "memory repo created" test -f "$MEMD/MEMORY.md"
chk ".gitattributes created" infile "$MEMD/.gitattributes" "merge=union"
chk "initial commit pushed" has "$(remote_log)" "Create memory repo"
chk "lint clean after install" M lint
chk "auto memory disabled" infile "$HOME/.claude/settings.json" '"autoMemoryEnabled": false'
if [ "$(uname)" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/dev.agent-memory.dream.plist"
  chk "launchd plist written" test -f "$PLIST"
  chk "launchd plist valid" plutil -lint "$PLIST"
fi

echo "== idempotent reinstall"
M install >/dev/null
chk "hooks not duplicated" test "$(grep -c 'hook session-start' "$HOME/.claude/settings.json")" -eq 1
chk "CLAUDE.md block once" test "$(grep -c 'agent-memory-kit:begin' "$HOME/.claude/CLAUDE.md")" -eq 1
chk "user allow rule kept" infile "$HOME/.claude/settings.json" 'Bash(npm test)'
chk "skill installed" infile "$HOME/.claude/skills/agent-memory/SKILL.md" "managed-by: agent-memory-kit"

echo "== new-project + session-start"
PROJ="$S/dev/VOID-RED"
mkdir -p "$PROJ/sub"
git -C "$PROJ" init -q
git -C "$PROJ" remote add origin git@github.com:void2610/VOID-RED.git
M new-project void2610/VOID-RED --title "VOID RED" >/dev/null
chk "project file" infile "$MEMD/projects/void-red.md" "repo: void2610/VOID-RED"
chk "project indexed" infile "$MEMD/projects/_index.md" "[[projects/void-red]]"
OUT=$(hook session-start "{\"session_id\":\"sess-111\",\"cwd\":\"$PROJ/sub\",\"source\":\"startup\"}")
CTX=$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)
chk "valid hook JSON" has "$CTX" "agent-memory"
chk "MEMORY.md injected" has "$CTX" "=== MEMORY.md ==="
chk "project memory injected" has "$CTX" "=== projects/void-red.md ==="
chk "index file not injected" hasnt "$CTX" "=== projects/_index.md ==="
chk "session id exposed" has "$CTX" "cc:sess-111"
OUT=$(hook session-start "{\"session_id\":\"s2\",\"cwd\":\"$S\",\"source\":\"startup\"}")
chk "non-repo cwd works" has "$OUT" "MEMORY.md"
OTHER="$S/dev/other"
mkdir -p "$OTHER"; git -C "$OTHER" init -q
git -C "$OTHER" remote add origin https://github.com/void2610/LiminalPalette.git
OUT=$(hook session-start "{\"session_id\":\"s3\",\"cwd\":\"$OTHER\",\"source\":\"startup\"}")
chk "hint for unknown project" has "$OUT" "mem new-project void2610/LiminalPalette"

echo "== post-edit: auto commit + debounced push"
echo "- 返答は日本語、箇条書きで簡潔に [source: cc:sess-111; added: 2026-10-07]" >> "$MEMD/user/preferences.md"
OUT=$(hook post-edit "{\"session_id\":\"sess-111\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$MEMD/user/preferences.md\"}}")
chk "commit notice" has "$OUT" "自動コミット"
chk "session trailer" has "$(git -C "$MEMD" log -1 --format=%B)" "Session: cc:sess-111"
sleep 16; waitsync
chk "pushed to remote" has "$(remote_log)" "update user/preferences.md"
OUT=$(hook post-edit "{\"tool_input\":{\"file_path\":\"$PROJ/README.md\"}}")
chk "edits outside memory ignored" empty "$OUT"

echo "== lint feedback"
echo "- Unity の罠は [[knowledge/unity/gotchas]] を参照 [added: 2026/10/07]" >> "$MEMD/projects/void-red.md"
OUT=$(hook post-edit "{\"session_id\":\"x\",\"tool_input\":{\"file_path\":\"$MEMD/projects/void-red.md\"}}")
chk "broken link reported" has "$OUT" "リンク切れ"
chk "bad date reported" has "$OUT" "added は YYYY-MM-DD"

echo "== secrets"
echo "- ビルドアカウント password: Hunter2Secret99x [added: 2026-10-07]" >> "$MEMD/knowledge/_index.md"
OUT=$(hook post-edit "{\"session_id\":\"x\",\"tool_input\":{\"file_path\":\"$MEMD/knowledge/_index.md\"}}")
chk "decision block" has "$OUT" '"decision": "block"'
chk "secret not committed" hasnt "$(git -C "$MEMD" log -p)" "Hunter2Secret99x"
M sync >/dev/null
chk "sweep refuses secret" hasnt "$(git -C "$MEMD" log -p)" "Hunter2Secret99x"
chk "status shows secret error" has "$(M status)" "secret"
delline "$MEMD/knowledge/_index.md" "Hunter2Secret99x"

echo "== mv rewrites links"
mkdir -p "$MEMD/knowledge/unity"
echo "# Unity の罠" > "$MEMD/knowledge/unity/gotchas.md"
echo "- [[knowledge/unity/gotchas]] — Unity で踏んだ罠" >> "$MEMD/knowledge/_index.md"
M commit -a -m "add unity" --no-sync >/dev/null
M mv knowledge/unity knowledge/unity6 >/dev/null
chk "links rewritten in index" infile "$MEMD/knowledge/_index.md" "[[knowledge/unity6/gotchas]]"
chk "links rewritten in project" infile "$MEMD/projects/void-red.md" "[[knowledge/unity6/gotchas]]"
subst "$MEMD/projects/void-red.md" "2026/10/07" "2026-10-07"
M commit -a -m fix --no-sync >/dev/null
chk "lint clean" M lint

echo "== union merge across machines"
waitsync; M sync >/dev/null
M2="$S/machine2/agent-memory"
git clone -q "$S/remote.git" "$M2"
echo "- 機械2で追記 [added: 2026-10-07]" >> "$M2/user/preferences.md"
git -C "$M2" commit -qam m2 && git -C "$M2" push -q origin main
echo "- 機械1で追記 [added: 2026-10-07]" >> "$MEMD/user/preferences.md"
M commit -a -m m1 --no-sync >/dev/null
M sync >/dev/null
chk "machine2 line merged" infile "$MEMD/user/preferences.md" "機械2"
chk "machine1 line kept" infile "$MEMD/user/preferences.md" "機械1"
chk "merged result pushed" has "$(remote_log)" "m1"

echo "== conflict (non-md) + resolve"
echo "SELECT 1;" > "$MEMD/knowledge/q.sql"
echo "- [[knowledge/q.sql]] テスト" >> "$MEMD/knowledge/_index.md"
M commit -a -m sql --no-sync >/dev/null; M sync >/dev/null
git -C "$M2" pull -q --rebase origin main
echo "SELECT 2;" > "$M2/knowledge/q.sql"
git -C "$M2" commit -qam m2sql && git -C "$M2" push -q origin main
echo "SELECT 3;" > "$MEMD/knowledge/q.sql"
M commit -a -m m1sql --no-sync >/dev/null
M sync >/dev/null
chk "conflict recorded" has "$(M status)" "rebase conflict"
chk "rebase aborted after failed sync" test ! -d "$MEMD/.git/rebase-merge"
OUT=$(hook session-start "{\"session_id\":\"s9\",\"cwd\":\"$S\",\"source\":\"startup\"}")
chk "session-start warns" has "$OUT" "競合あり"
M resolve >/dev/null
chk "resolve leaves markers" infile "$MEMD/knowledge/q.sql" "<<<<<<<"
OUT=$(hook post-edit "{\"tool_input\":{\"file_path\":\"$MEMD/knowledge/q.sql\"}}")
chk "no commit during rebase" has "$OUT" "resolve --continue"
printf 'SELECT 2;\n-- merged\n' > "$MEMD/knowledge/q.sql"
M resolve --continue >/dev/null
chk "rebase finished" test ! -d "$MEMD/.git/rebase-merge"
chk "resolution pushed" has "$(remote_show knowledge/q.sql)" "merged"

echo "== session-end sweep"
echo "- bash で追加した行 [added: 2026-10-07]" >> "$MEMD/user/profile.md"
hook session-end '{"session_id":"z","reason":"other"}'
sleep 1; waitsync
chk "leftovers committed and pushed" has "$(remote_show user/profile.md)" "bash で追加"

echo "== AGENT_MEMORY_HOOKS=off"
OUT=$(printf '{"session_id":"q","cwd":"/"}' | AGENT_MEMORY_HOOKS=off M hook session-start)
chk "no output when disabled" empty "$OUT"

echo "== digest"
TP="$HOME/.claude/projects/-dev-VOID-RED"; mkdir -p "$TP" "$HOME/.claude/projects/-mem"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
cat > "$TP/abc-123.jsonl" <<EOF
{"type":"user","sessionId":"abc-123","cwd":"$PROJ","timestamp":"$NOW","message":{"role":"user","content":"<system-reminder>noise</system-reminder>カードのシャッフルは Fisher-Yates で統一して"}}
{"type":"assistant","sessionId":"abc-123","cwd":"$PROJ","timestamp":"$NOW","message":{"role":"assistant","content":[{"type":"text","text":"了解です。Fisher-Yates に統一します。"},{"type":"tool_use","name":"Edit","input":{}}]}}
{"type":"user","sessionId":"abc-123","cwd":"$PROJ","timestamp":"$NOW","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"user","sessionId":"abc-123","cwd":"$PROJ","timestamp":"$NOW","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}
EOF
cat > "$HOME/.claude/projects/-mem/d.jsonl" <<EOF
{"type":"user","sessionId":"d","cwd":"$MEMD","timestamp":"$NOW","message":{"role":"user","content":"[agent-memory-dream] ..."}}
EOF
D=$(M digest --days 1)
chk "digest has user text" has "$D" "Fisher-Yates で統一して"
chk "digest has session id" has "$D" "cc:abc-123"
chk "system reminders stripped" hasnt "$D" "noise"
chk "sidechains skipped" hasnt "$D" "subagent prompt"
chk "memory-repo sessions skipped" hasnt "$D" "agent-memory-dream"

echo "== dream (stub claude, PR mode)"
mkdir -p "$S/bin"
cat > "$S/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$2"
report=$(printf '%s' "$prompt" | grep -o '/[^ ]*report.md' | head -1)
[ "${AGENT_MEMORY_HOOKS:-}" = off ] || { echo "hooks not disabled" >&2; exit 3; }
echo "- シャッフルは Fisher-Yates に統一 [source: cc:abc-123; added: 2026-10-07]" >> projects/void-red.md
printf '# Dreaming\n\n## 追加（1件）\n- projects/void-red: シャッフル方針\n' > "$report"
echo '{"result":"done"}'
EOF
printf '#!/bin/sh\nexit 1\n' > "$S/bin/gh"
chmod +x "$S/bin/claude" "$S/bin/gh"
OUT=$(PATH="$S/bin:$PATH" M dream --days 1)
echo "$OUT" | sed 's/^/    /'
chk "dream branch pushed" has "$(git --git-dir="$S/remote.git" branch)" "dream/"
chk "dream commit exists" has "$(git --git-dir="$S/remote.git" log --all --oneline)" "dream: "
chk "back on main" test "$(git -C "$MEMD" symbolic-ref --short HEAD)" = main
chk "main untouched until PR merge" hasnt "$(cat "$MEMD/projects/void-red.md")" "Fisher"
chk "dream state recorded" has "$(M status)" "dream/"

echo "== doctor"
M doctor | sed 's/^/    /'

echo "== uninstall"
M uninstall >/dev/null
chk "hooks removed" hasnt "$(cat "$HOME/.claude/settings.json")" "hook session"
chk "user settings kept" infile "$HOME/.claude/settings.json" 'Bash(npm test)'
chk "CLAUDE.md block removed" hasnt "$(cat "$HOME/.claude/CLAUDE.md")" "agent-memory-kit"
chk "skill removed" test ! -d "$HOME/.claude/skills/agent-memory"
chk "memory repo kept" test -f "$MEMD/MEMORY.md"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
