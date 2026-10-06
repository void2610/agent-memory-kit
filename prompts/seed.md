agent-memory スキルを使って、横断メモリの初期データを作ってください。対話しながら進めます。

1. まず {{MEM_DIR}}/meta/conventions.md を読む
2. 次の既存の情報源を読み、プロジェクトをまたいで役立つ内容を抽出する
   - ~/.claude/CLAUDE.md（agent-memory-kit のブロック以外）
   - ~/.claude/projects/*/memory/ 以下の Markdown（Claude Code の組み込み auto memory）
   - 私が以下に挙げるプロジェクトのリポジトリにある CLAUDE.md（プロジェクト固有の規約はそのまま残し、横断的な知識だけを抽出）
     <!-- 例: ~/dev/my-game, ~/dev/my-library -->
3. 抽出した候補を、保存先ファイルごとに一覧にして私に見せる。私の確認を取ってから書き込む
4. 次の順で作成する: user/profile, user/preferences, projects/（`mem new-project owner/name` で作成）, knowledge/
5. source はこのセッションの値か、元ファイルのパス（例: `source: ~/.claude/CLAUDE.md`）にする
6. 最後に `mem lint` を実行してエラーをゼロにする
