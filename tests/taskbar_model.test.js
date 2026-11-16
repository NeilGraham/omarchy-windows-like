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
