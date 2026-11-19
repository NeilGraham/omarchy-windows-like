// node tests/taskbar_model.test.js
const assert = require("node:assert/strict")
const test = require("node:test")
const M = require("../TaskbarModel.js")

const win = (key, over = {}) => ({ key, address: "0x" + Math.random().toString(16).slice(2, 8), workspaceId: 1, minimized: false, activated: false, ...over })

test("pinned apps come first, then running ones; windows of an app share a button", () => {
  const items = M.buildItems(["a.desktop", "b.desktop"], [win("c.desktop"), win("a.desktop"), win("c.desktop")], 1)
  assert.deepEqual(items.map(i => [i.key, i.pinned, i.windows.length]), [
    ["a.desktop", true, 1], ["b.desktop", true, 0], ["c.desktop", false, 2]])
})

test("windows on other workspaces are left out, minimized ones stay", () => {
  const items = M.buildItems([], [win("x", { workspaceId: 2 }), win("y", { workspaceId: -99, minimized: true })], 1)
  assert.deepEqual(items.map(i => i.key), ["y"])
})

test("dragged order: running apps anywhere, pins in their saved order, new ones placed", () => {
  const items = M.buildItems(["a", "b", "c"], [win("x"), win("y")], 1)
  const keys = order => M.arrange(items, order).map(i => i.key)
  assert.deepEqual(keys([]), ["a", "b", "c", "x", "y"])
  assert.deepEqual(keys(["x", "a", "y", "b", "c"]), ["x", "a", "y", "b", "c"])
  // The pins were reordered elsewhere (settings): their places keep, they follow the saved order.
  assert.deepEqual(keys(["x", "c", "y", "a", "b"]), ["x", "a", "y", "b", "c"])
  // A new pin goes after the last pin, a newly running app at the end.
  assert.deepEqual(keys(["x", "a", "b", "y"]), ["x", "a", "b", "c", "y"])
  assert.deepEqual(keys(["y", "a", "b", "c"]), ["y", "a", "b", "c", "x"])
  // Keys that are gone (closed, unpinned and not running) are skipped.
  assert.deepEqual(keys(["gone", "y", "a", "b", "c", "x"]), ["y", "a", "b", "c", "x"])
  assert.deepEqual(M.arrange(M.buildItems([], [win("x")], 1), ["a", "x"]).map(i => i.key), ["x"])
})

test("dragging a button: where it lands and who steps aside", () => {
  assert.deepEqual(M.move(["a", "b", "c", "d"], 0, 2), ["b", "c", "a", "d"])
  assert.deepEqual(M.move(["a", "b", "c", "d"], 3, 0), ["d", "a", "b", "c"])
  const centers = [5, 15, 25, 35]
  assert.equal(M.dropIndex(centers, 0, 9), 0)
  assert.equal(M.dropIndex(centers, 0, 16), 1)
  assert.equal(M.dropIndex(centers, 0, 99), 3)
  assert.equal(M.dropIndex(centers, 3, 14), 1)
  assert.deepEqual([0, 1, 2, 3].map(i => M.shiftFor(i, 0, 2, 10)), [0, -10, -10, 0])
  assert.deepEqual([0, 1, 2, 3].map(i => M.shiftFor(i, 3, 1, 10)), [0, 10, 10, 0])
  assert.deepEqual([0, 1, 2, 3].map(i => M.shiftFor(i, -1, 1, 10)), [0, 0, 0, 0])
})

test("a dragged order saves the pins' new order, keeping pins not shown in place", () => {
  assert.deepEqual(M.reorderPinned(["a", "b", "c"], ["x", "c", "a", "y", "b"]), ["c", "a", "b"])
  assert.deepEqual(M.reorderPinned(["a", "gone", "b"], ["b", "a"]), ["b", "gone", "a"])
})

test("buttons that don't fit go behind an overflow button", () => {
  assert.equal(M.fitCount([10, 10, 10], 2, 34, 6), 3)
  assert.equal(M.fitCount([10, 10, 10], 2, 33, 6), 2)
  assert.equal(M.fitCount([10, 10, 10], 2, 20, 6), 1)
  assert.equal(M.fitCount([10, 10, 10], 2, Infinity, 6), 3)
})

test("clicking: launch, focus, minimize the active one, cycle between several", () => {
  assert.equal(M.clickAction({ windows: [] }, 1).action, "launch")
  assert.deepEqual(M.clickAction({ windows: [win("a")] }, 1), { action: "focus", index: 0 })
  assert.deepEqual(M.clickAction({ windows: [win("a", { activated: true })] }, 1), { action: "minimize", index: 0 })
  assert.deepEqual(M.clickAction({ windows: [win("a", { activated: true }), win("a")] }, 1), { action: "focus", index: 1 })
  assert.deepEqual(M.clickAction({ windows: [win("a"), win("a", { activated: true })] }, 1), { action: "focus", index: 0 })
})

test("clicking prefers a window on this workspace over a minimized one", () => {
  const item = { windows: [win("a", { minimized: true, workspaceId: -99 }), win("a")] }
  assert.deepEqual(M.clickAction(item, 1), { action: "focus", index: 1 })
  assert.deepEqual(M.clickAction({ windows: [win("a", { minimized: true, workspaceId: -99 })] }, 1), { action: "focus", index: 0 })
})

test("a minimized window that was focused is brought back, not minimized again", () => {
  assert.equal(M.clickAction({ windows: [win("a", { minimized: true, activated: true })] }, 1).action, "focus")
})

test("indicators", () => {
  assert.equal(M.indicator({ windows: [] }), "none")
  assert.equal(M.indicator({ windows: [win("a")] }), "running")
  assert.equal(M.indicator({ windows: [win("a"), win("a", { activated: true })] }), "active")
})

test("recent apps: newest first, no repeats, capped", () => {
  assert.deepEqual(M.pushRecent(["b", "a", "c"], "a", 3), ["a", "b", "c"])
  assert.deepEqual(M.pushRecent(["b", "c", "d"], "a", 3), ["a", "b", "c"])
})

test("recently installed keeps known apps in order, without repeats", () => {
  const lines = "1700000003.5 new.desktop\n1700000002 gone.desktop\n1700000001 old.desktop\n1700000000 new.desktop\n"
  assert.deepEqual(M.recentlyInstalled(lines, ["new", "old"], 5), ["new", "old"])
  assert.deepEqual(M.recentlyInstalled(lines, ["new", "old"], 1), ["new"])
})

test("recommended takes turns, skips Start's pins and lets the next ones fill in", () => {
  const known = { a: "a", b: "b", c: "c", d: "d", e: "e", "f.desktop": "f", f: "f" }
  const idOf = id => known[id] || ""
  const rows = (installed, recent, pinned, max) => M.recommendations(installed, recent, pinned, idOf, max).map(r => r.id + ":" + r.why)
  assert.deepEqual(rows(["a", "b"], ["c", "a", "d"], [], 8), ["a:installed", "c:used", "b:installed", "d:used"])
  assert.deepEqual(rows(["a", "b"], ["c", "a", "d"], ["a", "c"], 8), ["b:installed", "d:used"])
  assert.deepEqual(rows(["a", "b", "e"], ["c", "d"], ["b"], 3), ["a:installed", "c:used", "d:used"])
  // Pins and lists may name an entry with or without .desktop; unknown ids drop out.
  assert.deepEqual(rows(["f.desktop", "gone"], ["f", "e"], [], 8), ["f:installed", "e:used"])
  assert.deepEqual(rows(["f"], ["e"], ["f.desktop"], 8), ["e:used"])
})

test("terminal apps are claimed by --app-id or org.omarchy.<command>", () => {
  const entries = [{ id: "btop", execString: "foot --app-id=btop btop", command: ["foot"], runInTerminal: false },
                   { id: "lazygit", command: ["/usr/bin/lazygit"], runInTerminal: true }]
  assert.equal(M.claimingEntryId("btop", entries), "btop")
  assert.equal(M.claimingEntryId("org.omarchy.lazygit", entries), "lazygit")
  assert.equal(M.claimingEntryId("other", entries), "")
})

test("all apps get a letter header per letter", () => {
  const rows = M.withLetterHeaders([{ n: "beta" }, { n: "Alpha" }, { n: "1Password" }, { n: "apple" }], a => a.n)
  assert.deepEqual(rows.map(r => r.header || r.app.n), ["#", "1Password", "A", "Alpha", "apple", "B", "beta"])
})
