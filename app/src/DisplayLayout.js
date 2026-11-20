.pragma library

// The Display page's arithmetic, kept apart from the page so the tests can
// run it: where displays stand, what they offer, and what each of Windows'
// "multiple displays" choices sets. Configs are Monitors::config() maps.

function clone(c) {
    return JSON.parse(JSON.stringify(c))
}

// A config's size on the desktop: its mode, turned and scaled. A display
// that doesn't say its size counts as 1920 × 1080, so it can still be shown
// and placed.
function logical(c) {
    const sideways = Number(c.transform) % 2 === 1
    const scale = Number(c.scale) > 0 ? Number(c.scale) : 1
    const width = Number(c.width) > 0 ? Number(c.width) : 1920
    const height = Number(c.height) > 0 ? Number(c.height) : 1080
    return {
        w: Math.round((sideways ? height : width) / scale),
        h: Math.round((sideways ? width : height) / scale)
    }
}

function rect(c) {
    const s = logical(c)
    return { x: Number(c.x), y: Number(c.y), w: s.w, h: s.h }
}

// The displays that take a place of their own: on, and not a copy of another.
function placed(configs) {
    return configs.filter(c => c.enabled && !c.mirror)
}

function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// Moves everything so the top-left display starts at 0,0, as Windows keeps
// its arrangement.
function normalize(configs) {
    const shown = placed(configs)
    if (shown.length === 0)
        return configs
    const minX = Math.min(...shown.map(c => Number(c.x)))
    const minY = Math.min(...shown.map(c => Number(c.y)))
    for (const c of shown) {
        c.x = Number(c.x) - minX
        c.y = Number(c.y) - minY
    }
    return configs
}

// One display changed size (resolution, scale, orientation) from `before`:
// the ones beyond its right or bottom edge move with that edge, so displays
// that touched still touch and none overlap.
function reflow(configs, name, before) {
    const changed = configs.find(c => c.name === name)
    if (!changed)
        return configs
    const after = rect(changed)
    const dw = after.w - before.w, dh = after.h - before.h
    for (const c of placed(configs)) {
        if (c.name === name)
            continue
        const r = rect(c)
        if (dw !== 0 && r.x >= before.x + before.w - 2)
            c.x = r.x + dw
        if (dh !== 0 && r.y >= before.y + before.h - 2)
            c.y = r.y + dh
    }
    return normalize(configs)
}

// A display left its place (`before`): the ones beyond its right edge move
// left into it, so no gap is left where it stood.
function closeGap(configs, before) {
    for (const c of placed(configs)) {
        const r = rect(c)
        if (r.x >= before.x + before.w - 2 && r.y < before.y + before.h && before.y < r.y + r.h)
            c.x = r.x - before.w
    }
    return configs
}

// Where a display dragged to x, y lands: against the side of another
// display nearest to it, lined up with that display's edge when close, and
// on top of none. Displays are dropped touching, as Windows snaps them.
function snap(configs, name, x, y) {
    const moving = configs.find(c => c.name === name)
    const others = placed(configs).filter(c => c.name !== name).map(rect)
    if (!moving || others.length === 0)
        return { x: 0, y: 0 }
    const size = logical(moving)
    const align = Math.max(size.w, size.h) * 0.08
    const candidates = []
    const along = (start, length, otherStart, otherLength) => {
        // Slid along the side, but still sharing some of it; lined up with
        // either end when near it.
        let v = Math.max(otherStart - length + 1, Math.min(start, otherStart + otherLength - 1))
        if (Math.abs(v - otherStart) < align)
            v = otherStart
        else if (Math.abs(v + length - (otherStart + otherLength)) < align)
            v = otherStart + otherLength - length
        return v
    }
    for (const o of others) {
        const ay = along(y, size.h, o.y, o.h)
        const ax = along(x, size.w, o.x, o.w)
        candidates.push({ x: o.x - size.w, y: ay }, { x: o.x + o.w, y: ay },
                        { x: ax, y: o.y - size.h }, { x: ax, y: o.y + o.h })
    }
    let best = null, bestDistance = Infinity
    for (const p of candidates) {
        const r = { x: p.x, y: p.y, w: size.w, h: size.h }
        if (others.some(o => overlaps(r, o)))
            continue
        const d = Math.hypot(p.x - x, p.y - y)
        if (d < bestDistance) {
            best = p
            bestDistance = d
        }
    }
    return best ? { x: Math.round(best.x), y: Math.round(best.y) } : { x: Number(moving.x), y: Number(moving.y) }
}

// Right of everything, for a display being turned on.
function nextFree(configs, name) {
    const shown = placed(configs).filter(c => c.name !== name).map(rect)
    if (shown.length === 0)
        return { x: 0, y: 0 }
    return { x: Math.max(...shown.map(r => r.x + r.w)), y: Math.min(...shown.map(r => r.y)) }
}

// ---------- What a display offers ----------

// Its resolutions, biggest first, each once: [{ width, height }].
function resolutions(modes) {
    const out = []
    for (const m of modes)
        if (!out.some(r => r.width === m.width && r.height === m.height))
            out.push({ width: m.width, height: m.height })
    return out
}

// Its refresh rates at one resolution, fastest first.
function rates(modes, width, height) {
    return modes.filter(m => m.width === width && m.height === height).map(m => m.refresh)
}

// The rate closest to `want` at a resolution (a new resolution keeps the
// rate it had where it can).
function closestRate(modes, width, height, want) {
    const list = rates(modes, width, height)
    if (list.length === 0)
        return want
    return list.reduce((best, r) => Math.abs(r - want) < Math.abs(best - want) ? r : best, list[0])
}

// The scale Windows would suggest: 96 dots per inch is 100 %, to the
// nearest 25 %. Null when the display doesn't say how big it is.
function recommendedScale(monitor) {
    const mm = Number(monitor.physicalWidth)
    const sideways = Number(monitor.transform) % 2 === 1
    const pixels = Number(sideways ? monitor.height : monitor.width) || 0
    const mode = (monitor.modes || [])[0]
    const native = mode ? (sideways ? mode.height : mode.width) : pixels
    if (!(mm > 0) || !(native > 0))
        return null
    const dpi = native / (mm / 25.4)
    return Math.min(3, Math.max(1, Math.round(dpi / 96 * 4) / 4))
}

// Inches corner to corner, from millimetres.
function diagonal(monitor) {
    const w = Number(monitor.physicalWidth), h = Number(monitor.physicalHeight)
    return w > 0 && h > 0 ? Math.round(Math.hypot(w, h) / 25.4 * 10) / 10 : 0
}

// ---------- Multiple displays ----------
//
// Each returns the configs to apply (every display whose settings change).

function configsOf(monitors) {
    return monitors.map(m => clone(m.config))
}

function changedOnly(before, after) {
    return after.filter(c => JSON.stringify(c) !== JSON.stringify(before.find(b => b.name === c.name)))
}

// The display shows a part of the desktop of its own, beside the others.
function extend(monitors, name) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    const c = configs.find(c => c.name === name)
    const wasPlaced = c.enabled && !c.mirror
    c.enabled = true
    c.mirror = ""
    if (!wasPlaced) {
        const p = nextFree(configs, name)
        c.x = p.x
        c.y = p.y
    }
    return changedOnly(before, normalize(configs))
}

// The display shows what `of` shows.
function duplicate(monitors, name, of) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    const c = configs.find(c => c.name === name)
    const had = c.enabled && !c.mirror ? rect(c) : null
    c.enabled = true
    c.mirror = of
    if (had)
        closeGap(configs, had)
    // Displays copying this one copy what it now copies.
    for (const other of configs)
        if (other.mirror === name)
            other.mirror = of
    return changedOnly(before, normalize(configs))
}

// Only this display is on.
function showOnly(monitors, name) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    for (const c of configs) {
        c.enabled = c.name === name
        if (c.name === name) {
            c.mirror = ""
            c.x = 0
            c.y = 0
        }
    }
    return changedOnly(before, configs)
}

// The display is turned off. Displays copying it go back to their own part
// of the desktop. Never the last one on.
function disconnect(monitors, name) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    if (placed(configs).filter(c => c.name !== name).length === 0)
        return []
    const gone = configs.find(c => c.name === name)
    if (gone && gone.enabled && !gone.mirror)
        closeGap(configs, rect(gone))
    for (const c of configs) {
        if (c.name === name) {
            c.enabled = false
            c.mirror = ""
        } else if (c.mirror === name) {
            c.mirror = ""
            const p = nextFree(configs, c.name)
            c.x = p.x
            c.y = p.y
        }
    }
    return changedOnly(before, normalize(configs))
}

// One display's settings changed (`change` is the keys that did); its
// neighbours move if its size did.
function change(monitors, name, values) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    const c = configs.find(c => c.name === name)
    const was = rect(c)
    Object.assign(c, values)
    if (c.enabled && !c.mirror)
        reflow(configs, name, was)
    return changedOnly(before, configs)
}

// A display dragged to x, y in desktop pixels.
function move(monitors, name, x, y) {
    const before = configsOf(monitors), configs = configsOf(monitors)
    const p = snap(configs, name, x, y)
    const c = configs.find(c => c.name === name)
    c.x = p.x
    c.y = p.y
    return changedOnly(before, normalize(configs))
}
