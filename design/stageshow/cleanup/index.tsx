import type { ComponentType } from 'react'
import { Archive, Check, Cpu, FileText, Globe, Grid3x3, Hammer, HardDrive, LayoutGrid, Laptop, List, MemoryStick, MessagesSquare, Package, RotateCw, Sparkles, type LucideProps } from 'lucide-react'
import { Button, Count, Roll, Spinner, Stage, States, Window, type Act } from '../../kit'
import './cleanup.css'

// nanokeep's Cleanup page as a hero. Beats: Developer is ticked and the chosen
// size rolls up on the Clean button; Clean is pressed, the ticked rows empty
// one by one, the disk dots drain and the found total rolls down. Scan Again
// is the reset: the scan finds the files again and the page returns to its
// opening frame.
//
// Real strings: the page title, the found total, the Clean button, the four
// categories the story touches and their sizes, and the sidebar, which is
// what makes it nanokeep rather than any settings window.

type Phase = 'idle' | 'cleaning' | 'done'
type S = { dev: boolean; cleaned: boolean[]; phase: Phase; scanning: boolean }

type Category = { id: string; title: string; desc: string; gb: number; color: string; icon: ComponentType<LucideProps>; on?: boolean }

const ROWS: Category[] = [
  { id: 'caches', title: 'Caches', desc: 'Apps make them again as they need them', gb: 2.1, color: '#0a84ff', icon: Archive, on: true },
  { id: 'developer', title: 'Developer', desc: "Xcode's builds and idle git worktrees", gb: 5.4, color: '#ff375f', icon: Hammer },
  { id: 'logs', title: 'Logs', desc: "Apps' logs and crash reports", gb: 0.64, color: '#ff9f0a', icon: FileText, on: true },
  { id: 'packages', title: 'Package Caches', desc: 'Downloads package managers fetch again', gb: 1.4, color: '#ff6b00', icon: Package },
  { id: 'agents', title: 'Agent Sessions', desc: "Claude Code's and Codex's old sessions", gb: 0, color: '#5ac8fa', icon: MessagesSquare },
]
const DEV = 1
const PICKED = [0, 1, 2]

const size = (gb: number) => (gb === 0 ? '–' : gb < 1 ? `${Math.round(gb * 1000)} MB` : `${gb.toFixed(1)} GB`)
const isOn = (s: S, i: number) => !s.cleaned[i] && (i === DEV ? s.dev : !!ROWS[i].on)
const chosen = (s: S) => ROWS.reduce((n, r, i) => n + (isOn(s, i) ? r.gb : 0), 0)
const found = (s: S) => ROWS.reduce((n, r, i) => n + (s.cleaned[i] ? 0 : r.gb), 0)

// The disk as dots, filled column by column as the app draws it: each found
// category in its color, then other files in gray, then free space
const DOT_ROWS = 4
const DOT_COLS = { wide: 60, compact: 38 }
const OTHER = 77
function dotColors(s: S, count: number) {
  const out: string[] = []
  const order = [0, 3, 1, 2]
  for (const i of order) {
    if (s.cleaned[i]) continue
    for (let n = 0; n < Math.round(ROWS[i].gb * 10); n++) out.push(ROWS[i].color)
  }
  for (let n = 0; n < OTHER; n++) out.push('var(--nk-dot-other)')
  while (out.length < count) out.push('var(--nk-dot-free)')
  return out.slice(0, count)
}

// Empty card surface: home sits between the total and the button before the
// tick, rest under the button after the clean
const HOME = { wide: { left: 500, top: 150 }, compact: { left: 160, top: 104 } }
const REST = { wide: { left: 590, top: 166 }, compact: { left: 250, top: 166 } }

const NONE = ROWS.map(() => false)
const initial: S = { dev: false, cleaned: NONE, phase: 'idle', scanning: false }
const POSTER: S = { dev: true, cleaned: ROWS.map((_, i) => PICKED.includes(i)), phase: 'done', scanning: false }

async function script(a: Act<S>) {
  await a.wait(900)
  a.mark('tick')
  await a.move({ at: 'check-developer', x: 0.5, y: 0.5 })
  await a.wait(150)
  await a.click()
  await a.set({ dev: true })
  await a.wait(1000)

  a.mark('clean')
  await a.move({ at: 'clean', x: 0.78, y: 0.62 })
  await a.wait(200)
  await a.click()
  await a.set({ phase: 'cleaning' })
  await a.wait(500)
  for (const i of PICKED) {
    await a.set((s) => ({ cleaned: s.cleaned.map((c, j) => c || j === i) }))
    await a.wait(260)
  }
  await a.wait(200)
  a.mark('done')
  await a.set({ phase: 'done' })
  await a.move('rest')
  await a.wait(2200)

  // Scan Again finds the files again, which is the loop's reset
  a.mark('rescan')
  await a.move({ at: 'rescan', x: 0.5, y: 0.55 })
  await a.wait(150)
  await a.click()
  await a.set({ scanning: true, phase: 'idle', dev: false })
  await a.wait(300)
  await a.set({ cleaned: NONE })
  await a.move('home')
  await a.set({ scanning: false })
  await a.wait(500)
}

const NAV: { label: string; icon: ComponentType<LucideProps>; tint: string; figure?: string; section?: string }[] = [
  { label: 'Overview', icon: LayoutGrid, tint: '#636366' },
  { label: 'Processes', icon: List, tint: '#8e8e93', figure: '849' },
  { label: 'CPU', icon: Cpu, tint: '#0a84ff', figure: '33%', section: 'Hardware' },
  { label: 'Memory', icon: MemoryStick, tint: '#30d158', figure: '84%' },
  { label: 'Disk', icon: HardDrive, tint: '#ff9f0a', figure: '786 KB/s' },
  { label: 'Network', icon: Globe, tint: '#30b0c7', figure: '25 KB/s' },
  { label: 'Apps', icon: Grid3x3, tint: '#8e8e93', figure: '214', section: 'System' },
  { label: 'Cleanup', icon: Sparkles, tint: '#ff9f0a' },
  { label: 'About This Mac', icon: Laptop, tint: '#8e8e93' },
]

function Sidebar({ total }: { total: number }) {
  return (
    <nav className="nk-nav">
      {NAV.map((n) => {
        const Glyph = n.icon
        const on = n.label === 'Cleanup'
        return (
          <div key={n.label} className="nk-nav-group">
            {n.section && <div className="nk-nav-section">{n.section}</div>}
            <div className="nk-nav-item" data-on={on || undefined}>
              <span className="nk-tile" style={{ background: n.tint }}>
                <Glyph size={12} strokeWidth={2.25} absoluteStrokeWidth />
              </span>
              <span className="nk-nav-label">{n.label}</span>
              <span className="nk-nav-figure">{on ? <Roll align="end" delay={400}>{size(total)}</Roll> : n.figure}</span>
            </div>
          </div>
        )
      })}
    </nav>
  )
}

function Checkbox({ on, ...rest }: { on: boolean } & Record<`data-${string}`, unknown>) {
  return (
    <span className="nk-check" data-on={on || undefined} {...rest}>
      <Check size={11} strokeWidth={3} absoluteStrokeWidth />
    </span>
  )
}

export default function NanokeepCleanup() {
  return (
    <Stage<S>
      width={720}
      height={400}
      compact={{ below: 640, width: 358, height: 340 }}
      initial={initial}
      poster={POSTER}
      script={script}
      accent="#f5458f"
      greys="cool"
      fidelity="realistic"
      cursor={{ at: { wide: { x: HOME.wide.left, y: HOME.wide.top }, compact: { x: HOME.compact.left, y: HOME.compact.top } } }}
      className="nk"
    >
      {(s, _rect, layout) => {
        // The totals hold while rows empty, then land once the clean is done
        const was = s.phase === 'cleaning' ? { ...s, cleaned: NONE } : s
        const total = found(was)
        const pick = chosen(was)
        const items = ROWS.filter((_, i) => isOn(was, i)).length
        const freed = ROWS.reduce((n, r, i) => n + (s.cleaned[i] ? r.gb : 0), 0)
        const cols = DOT_COLS[layout]
        const dots = dotColors(s, cols * DOT_ROWS)
        const label = s.phase === 'cleaning' ? 'Cleaning…' : s.phase === 'done' ? `Freed ${size(freed)}` : `Clean ${size(pick)}`
        const icon = s.phase === 'idle' ? undefined : <States value={s.phase} states={{ cleaning: <Spinner size={14} />, done: <Check size={14} strokeWidth={2.5} absoluteStrokeWidth /> }} />
        const sub = s.phase === 'done' ? 'Nothing chosen' : `${size(pick)} chosen · ${items} items`
        return (
          <>
            <Window
              className="nk-win"
              title="Cleanup"
              sidebar={layout === 'wide' ? <Sidebar total={total} /> : undefined}
              sidebarWidth={176}
              toolbar={
                <Button className="nk-rescan" data-target="rescan" data-spin={s.scanning || undefined} variant="secondary" size="medium" icon={<RotateCw size={14} strokeWidth={1.75} absoluteStrokeWidth />} aria-label="Scan Again" />
              }
              body={{ className: 'nk-body' }}
            >
              <div className="nk-card">
                <div className="nk-summary">
                  <span className="nk-hero-tile">
                    <Sparkles size={20} strokeWidth={1.75} absoluteStrokeWidth />
                  </span>
                  <div className="nk-figures">
                    <div className="nk-label">Found to clean</div>
                    <div className="nk-total">
                      <Count value={total} format={(n) => n.toFixed(1)} duration={900} />
                      <span className="nk-unit">GB</span>
                    </div>
                    <div className="nk-sub">
                      <Roll>{sub}</Roll>
                    </div>
                  </div>
                  <Button className="nk-clean" data-target="clean" variant="primary" size="large" icon={icon}>
                    {label}
                  </Button>
                </div>
                <div className="nk-dots" style={{ gridTemplateColumns: `repeat(${cols}, 4px)` }}>
                  {dots.map((c, i) => (
                    <span key={i} style={{ background: c, transitionDelay: `${Math.floor(i / DOT_ROWS) * 14}ms` }} />
                  ))}
                </div>
              </div>

              <div className="nk-table" data-crop>
                {ROWS.map((r, i) => {
                  const Glyph = r.icon
                  const empty = r.gb === 0
                  const gone = s.cleaned[i] || empty
                  return (
                    <div key={r.id} className="nk-row" data-gone={gone || undefined}>
                      {empty ? <span /> : <Checkbox on={isOn(s, i)} data-target={`check-${r.id}`} data-cursor="pointer" />}
                      <span className="nk-row-tile" style={{ color: r.color, background: `color-mix(in srgb, ${r.color} 14%, transparent)` }}>
                        <Glyph size={11} strokeWidth={2} absoluteStrokeWidth />
                      </span>
                      <span className="nk-row-text">
                        <span className="nk-row-title">{r.title}</span>
                        <span className="nk-row-desc">{r.desc}</span>
                      </span>
                      <span className="nk-row-size">
                        <Roll align="end" delay={s.scanning ? i * 90 : 0}>{s.cleaned[i] ? '–' : size(r.gb)}</Roll>
                      </span>
                    </div>
                  )
                })}
              </div>
            </Window>
            <span data-target="rest" className="nk-mark" style={REST[layout]} />
            <span data-target="home" className="nk-mark" style={HOME[layout]} />
          </>
        )
      }}
    </Stage>
  )
}
