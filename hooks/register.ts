// agent-memory-kit の hooks module（Claude Code の function hooks / mods）。
//
// 何をするか:
//   prompt.context  … 会話の最初のメッセージに、メモリ（MEMORY.md と今いるリポのプロジェクトメモリ）を注入する
//   tool.check      … メモリリポ配下へのファイル操作だけ、「確認」を「許可」に引き上げる（deny は尊重する）
//   tool.call       … メモリ内のファイルが編集されたら、lint・秘密情報検査・自動コミットし、結果をモデルに返す
//   session.end     … 取りこぼしの回収と push をバックグラウンドで始める
//   memory ツール    … モデルが使う操作（プロジェクト作成・移動・削除・lint・競合解消など）
//   /agent-memory   … 人が使うコマンド（init・status・dream など）
//
// 実処理はすべて bin/mem（Python 標準ライブラリのみ）が行う。このモジュールは呼び出しと判定だけを担う。
// プラグインがメモリリポの外に書き込むことはない。
import type { EngineInterface, Register } from 'claude-code'

type Engine = EngineInterface

// userConfig の値（register で設定する）と、メモリリポの実体パスのキャッシュ
let memoryDirOption = '~/agent-memory'
let python = 'python3'
let rootCache: string | undefined

const TOOL_NAME = 'memory'
const FILE_TOOLS = ['Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Grep', 'Glob']
const WRITE_TOOLS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit']

const TOOL_ACTIONS: Record<string, (i: Record<string, unknown>) => string[] | string> = {
  status: () => ['status'],
  lint: i => (typeof i.path === 'string' && i.path ? ['lint', i.path] : ['lint']),
  log: () => ['log'],
  sync: () => ['sync'],
  new_project: i => {
    if (typeof i.repo !== 'string' || !i.repo) return 'new_project には repo（owner/name）が必要'
    const args = ['new-project', i.repo]
    if (typeof i.title === 'string' && i.title) args.push('--title', i.title)
    if (typeof i.slug === 'string' && i.slug) args.push('--slug', i.slug)
    return args
  },
  mv: i =>
    typeof i.src === 'string' && typeof i.dst === 'string' ? ['mv', i.src, i.dst] : 'mv には src と dst が必要',
  rm: i => (typeof i.path === 'string' && i.path ? ['rm', i.path] : 'rm には path が必要'),
  resolve: () => ['resolve'],
  resolve_continue: () => ['resolve', '--continue'],
  resolve_abort: () => ['resolve', '--abort'],
}

const COMMAND_HELP = [
  '/agent-memory <サブコマンド>',
  '  init [private リポの URL]  メモリリポを作成（URL があれば clone / 初回 push）',
  '  status | doctor            状態と診断',
  '  sync                       今すぐ同期',
  '  lint | log                 検査 / 最近の変更',
  '  dream                      Dreaming（収穫と整理）をバックグラウンドで実行',
  '  seed                       初期データ投入用のプロンプトを入力欄に入れる',
  '  schedule                   Dreaming を定期実行する設定例を表示（何もインストールしない）',
].join('\n')

const PASS_THROUGH = ['status', 'doctor', 'sync', 'lint', 'log', 'schedule', 'path']


async function isDisabled($: Engine): Promise<boolean> {
  const v = ((await $.env.get('AGENT_MEMORY_HOOKS')) ?? '').toLowerCase()
  return v === 'off' || v === '0' || v === 'false' || v === 'no'
}

async function memDir($: Engine): Promise<string> {
  if (memoryDirOption === '~' || memoryDirOption.startsWith('~/')) {
    const home = (await $.env.get('HOME')) ?? ''
    return home + memoryDirOption.slice(1)
  }
  return memoryDirOption
}

// メモリリポの実体パス（シンボリックリンク解決済み）。まだ無ければ undefined
async function memRoot($: Engine): Promise<string | undefined> {
  if (rootCache !== undefined) return rootCache
  const stat = await $.fs.stat(await memDir($), { resolve: true }).catch(() => undefined)
  if (stat?.realPath !== undefined && stat.kind === 'dir') rootCache = stat.realPath.replace(/\/$/, '')
  return rootCache
}

// path が実際に置かれる場所（まだ無いファイルは親フォルダから求める）
async function placed($: Engine, path: string): Promise<string | undefined> {
  const own = await $.fs.stat(path, { resolve: true }).catch(() => undefined)
  if (own?.realPath !== undefined) return own.realPath
  const cut = path.lastIndexOf('/')
  const name = path.slice(cut + 1)
  if (name === '' || name === '.' || name === '..') return undefined
  const folder = cut < 0 ? '.' : path.slice(0, cut + 1)
  const dir = await $.fs.stat(folder, { resolve: true }).catch(() => undefined)
  return dir?.realPath === undefined ? undefined : `${dir.realPath.replace(/\/$/, '')}/${name}`
}

async function isInsideMemory($: Engine, path: unknown): Promise<boolean> {
  if (typeof path !== 'string' || path === '') return false
  const root = await memRoot($)
  if (root === undefined) return false
  const real = await placed($, path)
  if (real === undefined) return false
  if (real === `${root}/.git` || real.startsWith(`${root}/.git/`)) return false
  return real === root || real.startsWith(`${root}/`)
}

function pathOf(input: Record<string, unknown>): unknown {
  return input.file_path ?? input.notebook_path ?? input.path
}

async function mem($: Engine, args: readonly string[], timeoutMs = 30_000) {
  const dir = await memDir($)
  return $.process.run([python, `${$.plugin.root}/bin/mem`, '--mem-dir', dir, ...args], { timeoutMs })
}

function output(r: { exitCode: number; stdout: string; stderr: string }): string {
  const text = [r.stdout.trim(), r.stderr.trim()].filter(s => s !== '').join('\n')
  return text === '' ? `(exit ${r.exitCode})` : text
}

const OWN_TOOL = `mcp__agent-memory-kit__${TOOL_NAME}`

export const register: Register = (on, options) => {
  memoryDirOption = String(options.memory_dir ?? '~/agent-memory')
  python = String(options.python ?? 'python3')
  rootCache = undefined

  on('session.start', async ($, e, next) => {
    await $.tool.register({
      name: TOOL_NAME,
      description:
        'プロジェクト横断メモリ（Agent Memory Repo）の操作。記憶の読み書きは Read/Edit/Write で直接行い' +
        '（コミットは自動）、このツールはそれ以外に使う。action: status（状態）, lint（検査。path で個別）, log（最近の変更）, ' +
        'sync（今すぐ同期）, new_project（repo=owner/name, title, slug。projects/<slug>.md を作り索引に登録）, ' +
        'mv（src, dst。[[リンク]] も書き換える）, rm（path）, resolve / resolve_continue / resolve_abort（同期の競合解消）',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: Object.keys(TOOL_ACTIONS) },
          repo: { type: 'string', description: 'new_project: owner/name またはリポジトリ名' },
          title: { type: 'string', description: 'new_project: 表示名' },
          slug: { type: 'string', description: 'new_project: ファイル名（省略時は repo から）' },
          src: { type: 'string', description: 'mv: 移動元（メモリリポのルートからの相対パス）' },
          dst: { type: 'string', description: 'mv: 移動先' },
          path: { type: 'string', description: 'rm / lint: 対象（ルートからの相対パス）' },
        },
        required: ['action'],
      },
    }).catch(() => undefined)
    await $.command
      .register({
        name: 'agent-memory',
        description: '横断メモリ: init / status / sync / lint / log / doctor / dream / seed / schedule',
        argumentHint: '<subcommand> [args]',
      })
      .catch(() => undefined)
    if (e.isInteractive && !(await $.fs.exists(`${await memDir($)}/MEMORY.md`))) {
      $.ui.toast('agent-memory: メモリリポがまだありません。/agent-memory init で作成できます', { timeoutMs: 8000 })
    }
    return next(e)
  })

  on('prompt.context', async ($, e, next) => {
    const got = await next(e)
    if (await isDisabled($)) return got
    const r = await mem($, ['context', '--cwd', await $.session.cwd(), '--session', await $.session.id()], 20_000)
    const text = r.stdout.trim()
    if (r.exitCode !== 0 || text === '') return got
    return { ...got, blocks: [...got.blocks.filter(b => b.name !== 'agentMemory'), { name: 'agentMemory', text }] }
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision !== 'ask') return verdict // allow はそのまま、deny（ユーザーのルール）は尊重する
    if (e.tool === OWN_TOOL) return { decision: 'allow', reason: 'agent-memory-kit: 自身のメモリ操作ツール' }
    if (!FILE_TOOLS.includes(e.tool) || (await isDisabled($))) return verdict
    const input = (e.input ?? {}) as Record<string, unknown>
    if (await isInsideMemory($, pathOf(input))) {
      return { decision: 'allow', reason: 'agent-memory-kit: メモリリポ内のファイル操作' }
    }
    return verdict
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: 'mcp__agent-memory-kit__memory' }, async ($, e) => {
    const input = e as unknown as Record<string, unknown>
    const action = String(input.action ?? '')
    const build = TOOL_ACTIONS[action]
    if (build === undefined) return { result: `不明な action: ${action}（${Object.keys(TOOL_ACTIONS).join(', ')}）` }
    const args = build(input)
    if (typeof args === 'string') return { result: args }
    const r = await mem($, args, 120_000)
    return { result: output(r) }
  })

  on('tool.call', async ($, e, next) => {
    if (!WRITE_TOOLS.includes(e.tool)) return next(e)
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true || (await isDisabled($))) return ran
    const path = pathOf(e as unknown as Record<string, unknown>)
    if (typeof path !== 'string' || !(await isInsideMemory($, path))) return ran
    const r = await mem($, ['post-edit', path, '--session', await $.session.id()])
    let messages: string[] = []
    try {
      messages = (JSON.parse(r.stdout) as { messages?: string[] }).messages ?? []
    } catch {
      messages = [`agent-memory-kit: 自動コミットの結果を読めなかった（${output(r).slice(0, 300)}）`]
    }
    if (messages.length === 0) return ran
    return { ...ran, context: [...(ran.context ?? []), ...messages] }
  })

  on('command.run', { command: 'agent-memory' }, async ($, e) => {
    const [sub = 'status', ...rest] = e.args.trim().split(/\s+/).filter(s => s !== '')
    if (sub === 'help') return { text: COMMAND_HELP }
    if (sub === 'init') {
      const r = await mem($, rest[0] ? ['init', '--remote', rest[0]] : ['init'], 180_000)
      rootCache = undefined
      return { text: output(r) }
    }
    if (sub === 'dream') return { text: output(await mem($, ['dream', '--detach'])) }
    if (sub === 'seed') {
      const r = await mem($, ['seed'])
      if (r.exitCode !== 0) return { text: output(r) }
      await $.prompt.fill({ text: r.stdout.trim() + ' ', mode: 'replace' })
      return { text: '初期データ投入用のプロンプトを入力欄に入れました。対象のリポジトリを書き足して送信してください。' }
    }
    if (PASS_THROUGH.includes(sub)) return { text: output(await mem($, [sub], 120_000)) }
    return { text: `不明なサブコマンド: ${sub}\n\n${COMMAND_HELP}` }
  })

  on('session.end', async ($, e, next) => {
    if (!(await isDisabled($)) && (await $.fs.exists(`${await memDir($)}/MEMORY.md`))) {
      await mem($, ['sync', '--detach'], 3_000).catch(() => undefined)
    }
    return next(e)
  })
}
