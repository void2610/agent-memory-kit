// `claude plugin test .` で実行する。fs と process はテスト側の hook で偽装し、実環境には触れない。
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/home/u'
const MEM = `${HOME}/agent-memory`
const OWN_TOOL = 'mcp__agent-memory-kit__memory'

// 存在するパス（ディレクトリは末尾 /）。それ以外の stat は ENOENT で失敗させる
const EXISTING = [`${MEM}/`, `${MEM}/user/`, `${MEM}/user/preferences.md`, `${MEM}/.git/`, `${HOME}/dev/game/`]

type Ran = { argv: readonly string[] }

function world(on: On, opts: { env?: Record<string, string>; stdout?: string } = {}) {
  const runs: Ran[] = []
  mock.env(on, { HOME, ...(opts.env ?? {}) })
  on('fs.stat', ($, e) => {
    const path = e.path.replace(/\/$/, '')
    const hit = EXISTING.find(p => p.replace(/\/$/, '') === path)
    if (hit === undefined) throw new Error(`ENOENT: ${e.path}`)
    const kind = hit.endsWith('/') ? 'dir' : 'file'
    return { value: { kind, size: 0, mtimeMs: 0, isLink: false, ...(e.resolve ? { realPath: path } : {}) } }
  })
  on('fs.exists', ($, e) => ({ value: EXISTING.some(p => p.replace(/\/$/, '') === e.path.replace(/\/$/, '')) }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: `${HOME}/dev/game` }))
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv })
    return {
      value: { exitCode: 0, stdout: opts.stdout ?? '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  return runs
}

test('メモリリポ内のファイル操作だけ ask を allow に引き上げる', async ($, on) => {
  world(on)
  on('tool.check', () => ({ decision: 'ask' as const }))
  const inside = await $.tool.check({ tool: 'Edit', input: { file_path: `${MEM}/user/preferences.md` } })
  expect(inside.decision).toBe('allow')
  const newFile = await $.tool.check({ tool: 'Write', input: { file_path: `${MEM}/user/new.md` } })
  expect(newFile.decision).toBe('allow')
  const outside = await $.tool.check({ tool: 'Edit', input: { file_path: `${HOME}/dev/game/a.cs` } })
  expect(outside.decision).toBe('ask')
  const gitDir = await $.tool.check({ tool: 'Write', input: { file_path: `${MEM}/.git/config` } })
  expect(gitDir.decision).toBe('ask')
  const bash = await $.tool.check({ tool: 'Bash', input: { command: `rm -rf ${MEM}` } })
  expect(bash.decision).toBe('ask')
})

test('ユーザーの deny は覆さない', async ($, on) => {
  world(on)
  on('tool.check', () => ({ decision: 'deny' as const, reason: 'user rule' }))
  const r = await $.tool.check({ tool: 'Edit', input: { file_path: `${MEM}/user/preferences.md` } })
  expect(r.decision).toBe('deny')
})

test('自身の memory ツールは確認なしで通す', async ($, on) => {
  world(on)
  on('tool.check', () => ({ decision: 'ask' as const }))
  const r = await $.tool.check({ tool: OWN_TOOL, input: { action: 'status' } })
  expect(r.decision).toBe('allow')
})

test('メモリ内の編集の後に post-edit を呼び、結果をモデル向けのメモにする', async ($, on) => {
  const runs = world(on, { stdout: JSON.stringify({ status: 'committed', messages: ['自動コミットした'] }) })
  on('tool.call', () => ({ result: { ok: true } }))
  const r = await $.tool.call({
    tool: 'Edit',
    file_path: `${MEM}/user/preferences.md`,
    old_string: 'a',
    new_string: 'b',
  })
  expect(r.context).toEqual(['自動コミットした'])
  const argv = runs.at(-1)?.argv ?? []
  expect(argv).toContain('post-edit')
  expect(argv).toContain(`${MEM}/user/preferences.md`)
  expect(argv[argv.indexOf('--session') + 1]).toBe('sess-1')
})

test('メモリ外の編集では何もしない', async ($, on) => {
  const runs = world(on)
  on('tool.call', () => ({ result: { ok: true } }))
  const r = await $.tool.call({ tool: 'Edit', file_path: `${HOME}/dev/game/a.cs`, old_string: 'a', new_string: 'b' })
  expect(r.context).toBeUndefined()
  expect(runs.length).toBe(0)
})

test('最初のメッセージの文脈にメモリを注入する', async ($, on) => {
  const runs = world(on, { stdout: '<agent-memory>MEMO</agent-memory>\n' })
  on('prompt.context', ($, e) => ({ blocks: e.blocks }))
  const r = await $.prompt.context({ blocks: [{ name: 'currentDate', text: 'today' }] })
  expect(r.blocks.map(b => b.name)).toEqual(['currentDate', 'agentMemory'])
  expect(r.blocks.at(-1)?.text).toBe('<agent-memory>MEMO</agent-memory>')
  const argv = runs.at(-1)?.argv ?? []
  expect(argv).toContain('context')
  expect(argv[argv.indexOf('--cwd') + 1]).toBe(`${HOME}/dev/game`)
})

test('AGENT_MEMORY_HOOKS=off なら注入も自動コミットもしない', async ($, on) => {
  const runs = world(on, { env: { AGENT_MEMORY_HOOKS: 'off' }, stdout: 'MEMO' })
  on('prompt.context', ($, e) => ({ blocks: e.blocks }))
  on('tool.call', () => ({ result: { ok: true } }))
  const ctx = await $.prompt.context({ blocks: [] })
  expect(ctx.blocks.length).toBe(0)
  await $.tool.call({ tool: 'Write', file_path: `${MEM}/user/preferences.md`, content: 'x' })
  expect(runs.length).toBe(0)
})

test('memory ツールの new_project は mem new-project に変換される', async ($, on) => {
  const runs = world(on, { stdout: 'projects/my-game.md' })
  const r = await $.tool.call({ tool: OWN_TOOL, action: 'new_project', repo: 'you/my-game', title: 'My Game' })
  expect(r.result).toBe('projects/my-game.md')
  expect(runs.at(-1)?.argv.slice(-4)).toEqual(['new-project', 'you/my-game', '--title', 'My Game'])
})

test('memory ツールは引数が足りなければ実行しない', async ($, on) => {
  const runs = world(on)
  const r = await $.tool.call({ tool: OWN_TOOL, action: 'mv', src: 'a.md' })
  expect(String(r.result)).toContain('src と dst')
  expect(runs.length).toBe(0)
})

test('userConfig の memory_dir が mem に渡る', { options: { memory_dir: '/data/mem' } }, async ($, on) => {
  const runs = world(on, { stdout: 'ok' })
  await $.tool.call({ tool: OWN_TOOL, action: 'status' })
  const argv = runs.at(-1)?.argv ?? []
  expect(argv[argv.indexOf('--mem-dir') + 1]).toBe('/data/mem')
})
