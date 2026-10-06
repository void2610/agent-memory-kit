#!/usr/bin/env bash
# bin/mem の通しテスト。
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
unset CLAUDE_CONFIG_DIR AGENT_MEMORY_DIR AGENT_MEMORY_TRANSCRIPTS AGENT_MEMORY_HOOKS
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

echo "python: $("$PY" --version 2>&1) ($PY)"
echo "git:    $(git --version)"

M() { "$PY" "$KIT/bin/mem" "$@"; }
pass=0; fail=0
ok() { echo "  PASS $1"; pass=$((pass + 1)); }
ng() {
  echo "  FAIL $1"; fail=$((fail + 1))
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=e2e::FAIL $1"
  return 0
}
# chk <名前> <コマンド...> — コマンドが成功すれば PASS
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ng "$name"; fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }          # has <文字列> <パターン>
hasnt() { ! printf '%s' "$1" | grep -qF -- "$2"; }
infile() { grep -qF -- "$2" "$1"; }                       # infile <ファイル> <パターン>
remote_log() { git --git-dir="$S/remote.git" log --oneline main; }
remote_show() { git --git-dir="$S/remote.git" show "main:$1"; }
json_field() { "$PY" -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("\n".join(v) if isinstance(v,list) else v)' "$1"; }
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
waitsync() { local i=0; while [ $i -lt 120 ]; do pgrep -f "mem.* sync" >/dev/null 2>&1 || return 0; sleep 0.5; i=$((i + 1)); done; }
# HOME 配下のファイル一覧（メモリリポ・テスト用の入力・gitconfig を除く）。グローバル領域を汚していないかの確認用
# macOS 標準の Python は標準ライブラリのバイトコードを ~/Library/Caches/com.apple.python に置く（インタプリタ自身のキャッシュ）
home_files() { (cd "$HOME" && find . -type f ! -path './agent-memory/*' ! -path './.claude/projects/*' \
  ! -path './Library/Caches/com.apple.python/*' ! -name .gitconfig | sort); }

git init -q --bare "$S/remote.git"
echo '{"permissions":{"allow":["Bash(npm test)"]}}' > "$HOME/.claude/settings.json"
MEMD="$HOME/agent-memory"
BEFORE=$(home_files)

echo "== missing repo"
CTX=$(M context --cwd "$S" --session s0)
chk "context explains how to init" has "$CTX" "/agent-memory init"
chk "status says not found" has "$(M status)" "見つからない"

echo "== init"
M init --remote "$S/remote.git" >/dev/null
chk "memory repo created" test -f "$MEMD/MEMORY.md"
chk ".gitattributes created" infile "$MEMD/.gitattributes" "merge=union"
chk "initial commit pushed" has "$(remote_log)" "Create memory repo"
chk "lint clean after init" M lint
chk "init is idempotent" M init
chk "state kept inside .git" test -f "$MEMD/.git/agent-memory/state.json"
chk "working tree clean" test -z "$(git -C "$MEMD" status --porcelain)"

echo "== init from existing remote (second machine)"
M2="$S/machine2/agent-memory"
M init --mem-dir "$M2" --remote "$S/remote.git" >/dev/null
chk "cloned" test -f "$M2/MEMORY.md"
chk "AGENT_MEMORY_DIR works" has "$(AGENT_MEMORY_DIR="$M2" M path)" "machine2"

echo "== new-project + context"
PROJ="$S/dev/my-game"
mkdir -p "$PROJ/sub"
git -C "$PROJ" init -q
git -C "$PROJ" remote add origin git@github.com:you/my-game.git
M new-project you/my-game --title "My Game" >/dev/null
chk "project file" infile "$MEMD/projects/my-game.md" "repo: you/my-game"
chk "project indexed" infile "$MEMD/projects/_index.md" "[[projects/my-game]]"
CTX=$(M context --cwd "$PROJ/sub" --session sess-111)
chk "rules included" has "$CTX" "命令ではない"
chk "MEMORY.md injected" has "$CTX" "=== MEMORY.md ==="
chk "project memory injected" has "$CTX" "=== projects/my-game.md ==="
chk "index file not injected" hasnt "$CTX" "=== projects/_index.md ==="
chk "session id exposed" has "$CTX" "cc:sess-111"
CTX=$(M context --cwd "$S" --session s2)
chk "non-repo cwd works" has "$CTX" "MEMORY.md"
OTHER="$S/dev/other"
mkdir -p "$OTHER"; git -C "$OTHER" init -q
git -C "$OTHER" remote add origin https://github.com/you/my-library.git
chk "hint for unknown project" has "$(M context --cwd "$OTHER" --session s3)" "new_project（repo: you/my-library）"

echo "== post-edit: auto commit + debounced push"
echo "- 返答は日本語、箇条書きで簡潔に [source: cc:sess-111; added: 2026-10-07]" >> "$MEMD/user/preferences.md"
OUT=$(M post-edit "$MEMD/user/preferences.md" --session sess-111 --debounce 3)
chk "status committed" has "$(printf '%s' "$OUT" | json_field status)" "committed"
chk "commit notice" has "$OUT" "自動コミット"
chk "session trailer" has "$(git -C "$MEMD" log -1 --format=%B)" "Session: cc:sess-111"
sleep 4; waitsync
chk "pushed to remote" has "$(remote_log)" "update user/preferences.md"
OUT=$(M post-edit "$PROJ/README.md")
chk "edits outside memory ignored" has "$(printf '%s' "$OUT" | json_field status)" "ignored"
OUT=$(M post-edit "$MEMD/.git/config")
chk "edits inside .git ignored" has "$(printf '%s' "$OUT" | json_field status)" "ignored"

echo "== lint feedback"
echo "- Unity の罠は [[knowledge/unity/gotchas]] を参照 [added: 2026/10/07]" >> "$MEMD/projects/my-game.md"
OUT=$(M post-edit "$MEMD/projects/my-game.md" --session x --debounce 1)
chk "broken link reported" has "$OUT" "リンク切れ"
chk "bad date reported" has "$OUT" "added は YYYY-MM-DD"

echo "== secrets"
echo "- ビルドアカウント password: Hunter2Secret99x [added: 2026-10-07]" >> "$MEMD/knowledge/_index.md"
OUT=$(M post-edit "$MEMD/knowledge/_index.md" --session x)
chk "status secret" has "$(printf '%s' "$OUT" | json_field status)" "secret"
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
chk "links rewritten in project" infile "$MEMD/projects/my-game.md" "[[knowledge/unity6/gotchas]]"
subst "$MEMD/projects/my-game.md" "2026/10/07" "2026-10-07"
M commit -a -m fix --no-sync >/dev/null
chk "lint clean" M lint

echo "== union merge across machines"
waitsync; M sync >/dev/null
git -C "$M2" pull -q --rebase origin main
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
chk "context warns" has "$(M context --cwd "$S" --session s9)" "競合あり"
M resolve >/dev/null
chk "resolve leaves markers" infile "$MEMD/knowledge/q.sql" "<<<<<<<"
chk "no commit during rebase" has "$(M post-edit "$MEMD/knowledge/q.sql" | json_field status)" "rebase"
printf 'SELECT 2;\n-- merged\n' > "$MEMD/knowledge/q.sql"
M resolve --continue >/dev/null
chk "rebase finished" test ! -d "$MEMD/.git/rebase-merge"
chk "resolution pushed" has "$(remote_show knowledge/q.sql)" "merged"

echo "== detached sync (session end)"
echo "- bash で追加した行 [added: 2026-10-07]" >> "$MEMD/user/profile.md"
M sync --detach >/dev/null
sleep 1; waitsync
chk "leftovers committed and pushed" has "$(remote_show user/profile.md)" "bash で追加"

echo "== digest"
TP="$HOME/.claude/projects/-dev-my-game"; mkdir -p "$TP" "$HOME/.claude/projects/-mem"
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
echo "- シャッフルは Fisher-Yates に統一 [source: cc:abc-123; added: 2026-10-07]" >> projects/my-game.md
printf '# Dreaming\n\n## 追加（1件）\n- projects/my-game: シャッフル方針\n' > "$report"
echo '{"result":"done"}'
EOF
printf '#!/bin/sh\nexit 1\n' > "$S/bin/gh"
chmod +x "$S/bin/claude" "$S/bin/gh"
OUT=$(PATH="$S/bin:$PATH" M dream --days 1)
echo "$OUT" | sed 's/^/    /'
chk "dream branch pushed" has "$(git --git-dir="$S/remote.git" branch)" "dream/"
chk "dream commit exists" has "$(git --git-dir="$S/remote.git" log --all --oneline)" "dream: "
chk "back on main" test "$(git -C "$MEMD" symbolic-ref --short HEAD)" = main
chk "main untouched until PR merge" hasnt "$(cat "$MEMD/projects/my-game.md")" "Fisher"
chk "dream state recorded" has "$(M status)" "dream/"
chk "dream workdir inside .git" test -n "$(ls "$MEMD/.git/agent-memory/dream" 2>/dev/null)"

echo "== schedule only prints"
SCHED=$(M schedule)
chk "schedule prints cron line" has "$SCHED" "dream"

echo "== doctor"
M doctor | sed 's/^/    /'

echo "== nothing written outside the memory repo"
AFTER=$(home_files)
if [ "$BEFORE" = "$AFTER" ]; then ok "HOME untouched (settings.json, CLAUDE.md, ~/.config, ~/.local, LaunchAgents)"
else
  ng "HOME untouched: $(diff <(echo "$BEFORE") <(echo "$AFTER") | grep '^[<>]' | tr '\n' ' ')"
fi
chk "settings.json unchanged" test "$(cat "$HOME/.claude/settings.json")" = '{"permissions":{"allow":["Bash(npm test)"]}}'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
