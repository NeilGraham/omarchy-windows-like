pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons // qmllint disable import
import qs.Commons as Commons // qmllint disable import
import "TaskbarModel.js" as Model

// Windows-style window snapping for Omarchy's floating workspaces.
//
//   Drag a window (by its title bar, or with Super + drag) and let go:
//     - at the left or right edge      -> that half of the screen
//     - in a corner                    -> that quarter
//     - at the very top                -> maximized
//     - over the layout picker that appears near the top -> that zone
//   Drag a window's top or bottom border to the edge of the screen and it
//   stretches to the full height.
//   Super + Z opens the layout picker for the focused window.
//
// After a window snaps, "snap assist" offers the other windows for the rest of
// the layout. Dragging a snapped window away gives it back its old size.
//
// Drags are reported by the small drag-events Hyprland plugin in native/, as
// "custom" IPC events (see native/drag-events/main.cpp). Without it nothing
// snaps by dragging, but Super + Z still works.
//
// The layout picker, snap assist and zone geometry come from
// github.com/n0rthstar88/omarchy-snap-layouts (MIT); see CREDITS.md.
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string pluginId: "io.github.neilgraham.windows-like"

    // omarchy-windows-like settings (Windows-like Settings writes them).
    Settings {
        id: wl
        sourceDir: root.manifest && root.manifest.__sourceDir ? String(root.manifest.__sourceDir) : ""
    }

    // The overlay's fades: off with animations.enabled, and with Omarchy's
    // own switch (Style.duration is then 0). Windows glide by Hyprland's
    // windowsMove animation (hypr/windows-like.lua).
    function duration(ms) {
        return wl.get("animations.enabled", true) ? Style.duration(ms) : 0;
    }

    // ---------- Tunables ----------

    // How close (logical px) the pointer must be to a screen edge.
    readonly property int edgeDistance: 6
    // How far along an edge from a corner still counts as that corner.
    readonly property int cornerSize: 80
    // How close to the top of the work area the picker appears.
    readonly property int pickerDistance: 36
    // Edges shared with another monitor snap only after the pointer rests on
    // them this long, so carrying a window across screens doesn't snap it.
    readonly property int sharedEdgeDwell: 350

    // Zones are [x, y, width, height] as fractions of the usable screen area.
    readonly property var layouts: [
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]],
        [[0, 0, 2 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
        [[0, 0, 1 / 3, 1], [1 / 3, 0, 2 / 3, 1]],
        [[0, 0, 1 / 3, 1], [1 / 3, 0, 1 / 3, 1], [2 / 3, 0, 1 / 3, 1]],
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]],
        [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]]
    ]
    // Edge snaps reuse the layouts so snap assist knows what is left to fill.
    readonly property var halves: ({ left: [0, 0], right: [0, 1] })
    readonly property var quarters: ({ tl: [5, 0], tr: [5, 1], bl: [5, 2], br: [5, 3] })

    // ---------- Hyprland settings, read at start and on every reload ----------

    property int borderSize: 2
    property int gapsOut: 10
    property int gapsIn: 5
    property int barHeight: 30
    property bool hasTitleBars: false
    // The tab bar the native plugin draws on a window with tabs but no title bar
    // (with a title bar, the tabs sit in it).
    property int tabBarHeight: 0
    // Snapped windows meet each other and the screen's edges, as on Windows;
    // snapping.gaps keeps Hyprland's gaps between them instead.
    readonly property bool snapGaps: wl.get("snapping.gaps", false) === true
    readonly property int snapGapOut: snapGaps ? gapsOut : 0
    readonly property int innerGap: snapGaps ? 2 * gapsIn : 0
    // Omarchy's title bars draw on windows with this tag only.
    readonly property string floatingTag: "omarchy-floating-workspace"

    function parseOption(text) {
        var m = String(text).match(/(?:int|float|css gap data):\s*(-?\d+)/);
        return m ? Number(m[1]) : NaN;
    }

    Process {
        id: optionsProc
        command: ["sh", "-c", "for o in general:border_size general:gaps_out general:gaps_in plugin:hyprbars:bar_height plugin:windows_like:tab_height; do hyprctl getoption $o 2>/dev/null | head -1; printf '\\n@@OWL@@\\n'; done; hyprctl -j plugin list"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var s = String(text).split("\n@@OWL@@\n");
                var v = s.map(root.parseOption);
                if (!isNaN(v[0])) root.borderSize = v[0];
                if (!isNaN(v[1])) root.gapsOut = v[1];
                if (!isNaN(v[2])) root.gapsIn = v[2];
                if (!isNaN(v[3])) root.barHeight = v[3];
                root.tabBarHeight = isNaN(v[4]) ? 0 : v[4];
                try {
                    root.hasTitleBars = JSON.parse(s[5] || "[]").some(function(p) {
                        return p.name === "hyprbars";
                    });
                } catch (e) {
                    root.hasTitleBars = false;
                }
            }
        }
    }

    Timer {
        id: reloadOptions
        interval: 500
        onTriggered: if (!optionsProc.running) optionsProc.running = true
    }

    // ---------- Monitors and windows ----------

    // { name, x, y, w, h, reserved: [l, t, r, b], workspaceId }, logical px.
    property var monitors: []
    property var monitorsIpc: []
    property var clients: []
    // The monitor the overlay is on.
    property var monitor: null

    function monitorFromIpc(m) {
        var scale = Number(m.scale) || 1;
        var rotated = Number(m.transform) % 2 === 1;
        return {
            id: Number(m.id),
            name: String(m.name),
            x: Number(m.x),
            y: Number(m.y),
            w: (rotated ? m.height : m.width) / scale,
            h: (rotated ? m.width : m.height) / scale,
            reserved: m.reserved && m.reserved.length === 4 ? m.reserved.map(Number) : [0, 0, 0, 0],
            workspaceId: m.activeWorkspace ? Number(m.activeWorkspace.id) : 1
        };
    }

    function monitorAt(x, y) {
        for (var i = 0; i < root.monitors.length; i++) {
            var m = root.monitors[i];
            if (x >= m.x && x < m.x + m.w && y >= m.y && y < m.y + m.h)
                return m;
        }
        return null;
    }

    function monitorById(id) {
        for (var i = 0; i < root.monitorsIpc.length; i++)
            if (Number(root.monitorsIpc[i].id) === Number(id))
                return root.monitorFromIpc(root.monitorsIpc[i]);
        return null;
    }

    // Whether another monitor sits right against this edge of m.
    function edgeShared(m, edge) {
        for (var i = 0; i < root.monitors.length; i++) {
            var o = root.monitors[i];
            if (o.name === m.name)
                continue;
            var overlapY = o.y < m.y + m.h && o.y + o.h > m.y;
            var overlapX = o.x < m.x + m.w && o.x + o.w > m.x;
            if (edge === "left" && overlapY && Math.abs(o.x + o.w - m.x) <= 1) return true;
            if (edge === "right" && overlapY && Math.abs(m.x + m.w - o.x) <= 1) return true;
            if (edge === "top" && overlapX && Math.abs(o.y + o.h - m.y) <= 1) return true;
            if (edge === "bottom" && overlapX && Math.abs(m.y + m.h - o.y) <= 1) return true;
        }
        return false;
    }

    // The area snapped windows fill: inside the bar, and inside the outer
    // gaps when snapping.gaps is on.
    function workArea(m) {
        var r = m.reserved;
        var g = root.snapGapOut;
        return {
            x: m.x + r[0] + g,
            y: m.y + r[1] + g,
            w: m.w - r[0] - r[2] - 2 * g,
            h: m.h - r[1] - r[3] - 2 * g
        };
    }

    // A zone's outer box (border and title bar included), global logical px.
    function zoneOuterRect(m, layoutIndex, zoneIndex) {
        var a = root.workArea(m);
        var z = root.layouts[layoutIndex][zoneIndex];
        var half = root.innerGap / 2;
        var x1 = a.x + z[0] * a.w + (z[0] > 0.001 ? half : 0);
        var x2 = a.x + (z[0] + z[2]) * a.w - (z[0] + z[2] < 0.999 ? half : 0);
        var y1 = a.y + z[1] * a.h + (z[1] > 0.001 ? half : 0);
        var y2 = a.y + (z[1] + z[3]) * a.h - (z[1] + z[3] < 0.999 ? half : 0);
        // Round the edges, not the sizes, so neighbours share an exact edge.
        var left = Math.round(x1), right = Math.round(x2);
        var topEdge = Math.round(y1), bottom = Math.round(y2);
        return { x: left, y: topEdge, w: right - left, h: bottom - topEdge };
    }

    // Other windows standing the whole height of m's work area on its
    // workspace: snapped ones, and any stretched from top to bottom. Their
    // outer left and right edges, border and title bar included.
    function fullHeightNeighbors(m, exceptAddress) {
        var a = root.workArea(m);
        var tolerance = Math.max(24, 2 * root.gapsOut);
        var out = [];
        for (var i = 0; i < root.clients.length; i++) {
            var c = root.clients[i];
            if (!c || c.address === exceptAddress || c.hidden === true || c.mapped === false || c.floating !== true
                    || Number(c.fullscreen) > 0 || !c.workspace || Number(c.workspace.id) !== m.workspaceId
                    || (c.monitor !== undefined && Number(c.monitor) !== m.id) || !c.at || !c.size)
                continue;
            var b = root.borderSize;
            var top = c.at[1] - root.titleBarFor(c) - b;
            var bottom = c.at[1] + c.size[1] + b;
            if (top > a.y + tolerance || bottom < a.y + a.h - tolerance)
                continue;
            out.push({ left: c.at[0] - b, right: c.at[0] + c.size[0] + b });
        }
        return out;
    }

    // A left or right zone (a half, or a quarter) fitted to the room beside
    // full-height windows: snapped next to a window that was snapped and then
    // resized, it fills what that window leaves; beside a window stretched
    // down the middle, it fills the side, so three can stand side by side.
    // Null when nothing is in the way, or the room is too narrow: then the
    // plain zone applies.
    readonly property int minFitWidth: 160
    function fittedZone(m, layoutIndex, zoneIndex, side) {
        if (!wl.get("snapping.fillSpace", true))
            return null;
        var r = root.zoneOuterRect(m, layoutIndex, zoneIndex);
        var a = root.workArea(m);
        var neighbors = root.fullHeightNeighbors(m, root.dragAddress);
        var bound = null;
        for (var i = 0; i < neighbors.length; i++) {
            var n = neighbors[i];
            if (side === "left" && n.left > a.x + root.minFitWidth && (bound === null || n.left < bound))
                bound = n.left;
            if (side === "right" && n.right < a.x + a.w - root.minFitWidth && (bound === null || n.right > bound))
                bound = n.right;
        }
        if (bound === null)
            return null;
        if (side === "left") {
            var x2 = Math.round(bound - root.innerGap);
            return x2 - r.x >= root.minFitWidth ? { x: r.x, y: r.y, w: x2 - r.x, h: r.h } : null;
        }
        var x1 = Math.round(bound + root.innerGap);
        var right = r.x + r.w;
        return right - x1 >= root.minFitWidth ? { x: x1, y: r.y, w: right - x1, h: r.h } : null;
    }

    function clientByAddress(address) {
        for (var i = 0; i < root.clients.length; i++)
            if (root.clients[i].address === address)
                return root.clients[i];
        return null;
    }

    // Everything drawn above a window's content: Omarchy's title bar (tabs sit
    // inside it), or, for a window with tabs but no title bar, the tab bar.
    function titleBarFor(client) {
        if (!client)
            return 0;
        if (root.hasTitleBars && client.tags)
            for (var i = 0; i < client.tags.length; i++)
                if (String(client.tags[i]).replace(/\*$/, "") === root.floatingTag)
                    return root.barHeight;
        return client.grouped && client.grouped.length > 1 ? root.tabBarHeight : 0;
    }

    function validAddress(a) {
        return /^0x[0-9a-fA-F]{1,16}$/.test(String(a));
    }

    // ---------- Placing windows ----------

    // Sizes from before a window was snapped, so dragging it out restores them:
    // address -> { w, h, placed: { w, h } }
    property var restoreSizes: ({})

    function run(lua) {
        Quickshell.execDetached(["hyprctl", "eval", lua.join("; ")]);
    }

    // Puts a window's outer box (border and title bar included) at rect.
    function placeOuter(address, rect, workspaceId) {
        if (!root.validAddress(address))
            return;
        var c = root.clientByAddress(address);
        var sel = "address:" + address;
        var bar = root.titleBarFor(c);
        var b = root.borderSize;
        var w = Math.max(1, Math.round(rect.w - 2 * b));
        var h = Math.max(1, Math.round(rect.h - 2 * b - bar));
        var x = Math.round(rect.x + b);
        var y = Math.round(rect.y + b + bar);
        var lua = [];
        if (c && workspaceId !== undefined && c.workspace && Number(c.workspace.id) !== workspaceId)
            lua.push("hl.dispatch(hl.dsp.window.move({ workspace = '" + Number(workspaceId) + "', follow = false, window = '" + sel + "' }))");
        if (c && Number(c.fullscreen) > 0)
            lua.push("hl.dispatch(hl.dsp.window.fullscreen({ mode = 'maximized', action = 'unset', window = '" + sel + "' }))");
        if (c && c.floating === false)
            lua.push("hl.dispatch(hl.dsp.window.float({ action = 'on', window = '" + sel + "' }))");
        // Move, then resize, then move again: Hyprland rounds a resize
        // differently while the window hangs off the screen, as a window
        // dragged to an edge does, and a resize can shift a window it clamps.
        var moveTo = "hl.dispatch(hl.dsp.window.move({ x = " + x + ", y = " + y + ", window = '" + sel + "' }))";
        lua.push(moveTo);
        lua.push("hl.dispatch(hl.dsp.window.resize({ x = " + w + ", y = " + h + ", relative = false, window = '" + sel + "' }))");
        lua.push(moveTo);
        lua.push(root.raiseLua(sel));
        root.run(lua);
        root.rememberSize(address, c, w, h);
        // Snap assist's overlay holds the keyboard while it is open, so focus
        // asked for now can be refused; ask again once it has closed.
        root.focusAfter = address;
        focusTimer.restart();
    }

    // Focus and raise one window by address (bring_to_top only ever raises
    // whichever window is focused).
    function raiseLua(sel) {
        return "hl.dispatch(hl.dsp.focus({ window = '" + sel + "' })); "
            + "hl.dispatch(hl.dsp.window.alter_zorder({ mode = 'top', window = '" + sel + "' }))";
    }

    property string focusAfter: ""
    Timer {
        id: focusTimer
        interval: 120
        onTriggered: {
            if (!root.opened && root.validAddress(root.focusAfter))
                root.run([root.raiseLua("address:" + root.focusAfter)]);
        }
    }

    function rememberSize(address, c, w, h) {
        var sizes = Object.assign({}, root.restoreSizes);
        var old = sizes[address];
        // Keep the size from before the first snap through later snaps.
        var orig = old ? { w: old.w, h: old.h } : (c && c.size ? { w: c.size[0], h: c.size[1] } : null);
        if (orig)
            sizes[address] = { w: orig.w, h: orig.h, placed: { w: w, h: h } };
        root.restoreSizes = sizes;
    }

    function placeInZone(address, m, layoutIndex, zoneIndex) {
        root.placeOuter(address, root.zoneOuterRect(m, layoutIndex, zoneIndex), m.workspaceId);
    }

    function maximize(address) {
        if (!root.validAddress(address))
            return;
        var c = root.clientByAddress(address);
        if (c && c.size)
            root.rememberSize(address, c, -1, -1);
        root.run(["hl.dispatch(hl.dsp.window.fullscreen({ mode = 'maximized', action = 'set', window = 'address:" + address + "' }))"]);
    }

    // A snapped window dragged into open space gets its old size back, with
    // the pointer keeping its place along the title bar.
    function restoreAfterDrag(address, ev) {
        var saved = root.restoreSizes[address];
        if (!saved || !root.validAddress(address))
            return;
        var sizes = Object.assign({}, root.restoreSizes);
        delete sizes[address];
        root.restoreSizes = sizes;
        if (saved.placed.w < 0 || Math.abs(ev.w - saved.placed.w) > 2 || Math.abs(ev.h - saved.placed.h) > 2)
            return;
        var along = ev.w > 0 ? (ev.cx - ev.x) / ev.w : 0.5;
        var x = Math.round(ev.cx - along * saved.w);
        var sel = "address:" + address;
        var moveTo = "hl.dispatch(hl.dsp.window.move({ x = " + x + ", y = " + Math.round(ev.y) + ", window = '" + sel + "' }))";
        root.run([
            moveTo,
            "hl.dispatch(hl.dsp.window.resize({ x = " + Math.round(saved.w) + ", y = " + Math.round(saved.h) + ", relative = false, window = '" + sel + "' }))",
            moveTo
        ]);
    }

    // ---------- Dragging ----------

    property bool dragActive: false
    property string dragMode: ""
    property string dragAddress: ""
    property bool dragSnappable: false
    property bool snapshotReady: false
    property var lastDrag: null
    // null, or { type: "zone", layout, zone, fromCard } | { type: "max" } | { type: "vmax", rect }
    property var target: null
    property bool showCard: false
    property string pendingEdge: ""
    property double pendingEdgeSince: 0

    function parseDrag(data) {
        var f = String(data).split("|");
        if (f.length < 9)
            return null;
        var n = f.slice(3, 9).map(Number);
        if (n.some(isNaN) || !root.validAddress(f[2]))
            return null;
        return { kind: f[0], mode: f[1], address: f[2], cx: n[0], cy: n[1], x: n[2], y: n[3], w: n[4], h: n[5] };
    }

    function handleDragEvent(data) {
        var ev = root.parseDrag(data);
        if (!ev)
            return;
        if (ev.kind === "start") {
            if (root.mode === "assist" || root.mode === "picker")
                root.close();
            root.dragActive = true;
            root.dragMode = ev.mode;
            root.dragAddress = ev.address;
            root.dragSnappable = false;
            root.snapshotReady = false;
            root.target = null;
            root.showCard = false;
            root.pendingEdge = "";
            root.lastDrag = ev;
            root.requestSnapshot("drag");
        } else if (ev.kind === "move" && root.dragActive && ev.address === root.dragAddress) {
            root.lastDrag = ev;
            root.updateTarget(ev);
        } else if (ev.kind === "end" && root.dragActive && ev.address === root.dragAddress) {
            root.lastDrag = ev;
            root.updateTarget(ev);
            root.finishDrag(ev);
        }
    }

    function updateTarget(ev) {
        if (!root.dragEnabled || !root.snapshotReady || !root.dragSnappable) {
            root.target = null;
            root.showCard = false;
            return;
        }
        var m = root.monitorAt(ev.cx, ev.cy);
        if (!m) {
            root.target = null;
            root.showCard = false;
            return;
        }
        // Each drag's snapshot makes new monitor objects, whose workspaceId is
        // the workspace shown now: keep the old one and a snap would carry the
        // window to whichever workspace the first drag was on.
        if (root.monitor !== m)
            root.monitor = m;
        var t = ev.mode === "move" ? root.moveTarget(ev, m) : root.resizeTarget(ev, m);
        root.target = t;
        if (t && t.type === "zone" && t.fromCard) {
            root.hoverLayout = t.layout;
            root.hoverZone = t.zone;
        } else {
            root.hoverLayout = -1;
            root.hoverZone = -1;
        }
        if (root.pendingEdge !== "")
            dwellTimer.restart();
    }

    // Edges shared with another screen wait for the pointer to rest.
    function dwellOk(m, edge) {
        var shared = edge.split("+").some(function(e) {
            return root.edgeShared(m, e);
        });
        if (!shared) {
            root.pendingEdge = "";
            return true;
        }
        if (root.pendingEdge !== m.name + ":" + edge) {
            root.pendingEdge = m.name + ":" + edge;
            root.pendingEdgeSince = Date.now();
            return false;
        }
        return Date.now() - root.pendingEdgeSince >= root.sharedEdgeDwell;
    }

    function moveTarget(ev, m) {
        var lx = ev.cx - m.x, ly = ev.cy - m.y;
        var E = root.edgeDistance, C = root.cornerSize;
        var atLeft = lx <= E, atRight = lx >= m.w - 1 - E;
        var atTop = ly <= E, atBottom = ly >= m.h - 1 - E;
        var nearLeft = lx <= C, nearRight = lx >= m.w - 1 - C;
        var nearTop = ly <= C, nearBottom = ly >= m.h - 1 - C;

        var corner = "";
        if ((atLeft && nearTop) || (atTop && nearLeft)) corner = "tl";
        else if ((atRight && nearTop) || (atTop && nearRight)) corner = "tr";
        else if ((atLeft && nearBottom) || (atBottom && nearLeft)) corner = "bl";
        else if ((atRight && nearBottom) || (atBottom && nearRight)) corner = "br";
        if (corner !== "" && !wl.get("snapping.corners", true))
            corner = "";
        if (corner !== "") {
            root.showCard = false;
            var edges = (corner[0] === "t" ? "top" : "bottom") + "+" + (corner[1] === "l" ? "left" : "right");
            if (!root.dwellOk(m, edges))
                return null;
            var q = root.quarters[corner];
            return { type: "zone", layout: q[0], zone: q[1], fromCard: false,
                     rect: root.fittedZone(m, q[0], q[1], corner[1] === "l" ? "left" : "right") };
        }
        if ((atLeft || atRight) && wl.get("snapping.edges", true)) {
            root.showCard = false;
            if (!root.dwellOk(m, atLeft ? "left" : "right"))
                return null;
            var h = root.halves[atLeft ? "left" : "right"];
            return { type: "zone", layout: h[0], zone: h[1], fromCard: false,
                     rect: root.fittedZone(m, h[0], h[1], atLeft ? "left" : "right") };
        }

        // Near the top: the layout picker, or maximize at the very edge.
        // The card opens when the pointer reaches the top and stays open while
        // it moves down onto the card.
        var cr = root.cardRect();
        root.showCard = wl.get("snapping.picker", true) && (ly <= m.reserved[1] + root.pickerDistance
            || (root.showCard && ly <= cr.y + cr.h + 48 && lx >= cr.x - 48 && lx <= cr.x + cr.w + 48));
        if (root.showCard) {
            var hit = root.hitTest(lx, ly);
            if (hit.layout >= 0)
                return { type: "zone", layout: hit.layout, zone: hit.zone, fromCard: true };
        }
        root.pendingEdge = "";
        if (atTop && !root.edgeShared(m, "top") && wl.get("snapping.topMaximizes", true))
            return { type: "max" };
        return null;
    }

    // Dragging the top or bottom border to the edge of the work area stretches
    // the window from the top of the work area to the bottom.
    function resizeTarget(ev, m) {
        root.showCard = false;
        if (!wl.get("snapping.stretch", true))
            return null;
        var c = root.clientByAddress(ev.address);
        var bar = root.titleBarFor(c);
        var b = root.borderSize;
        var a = root.workArea(m);
        var areaTop = m.y + m.reserved[1];
        var areaBottom = m.y + m.h - m.reserved[3];
        var outerTop = ev.y - bar - b;
        var outerBottom = ev.y + ev.h + b;
        var E = root.edgeDistance;
        var topHit = ev.cy <= areaTop + E && Math.abs(ev.cy - outerTop) <= 48;
        var bottomHit = ev.cy >= areaBottom - 1 - E && Math.abs(ev.cy - outerBottom) <= 48;
        if (!topHit && !bottomHit)
            return null;
        // Round the edges, not the height, as the zones do.
        var top = Math.round(a.y), bottom = Math.round(a.y + a.h);
        return { type: "vmax", rect: { x: ev.x - b, y: top, w: ev.w + 2 * b, h: bottom - top } };
    }

    // Lets a pointer resting on a shared edge snap without moving again.
    Timer {
        id: dwellTimer
        interval: root.sharedEdgeDwell + 20
        onTriggered: if (root.dragActive && root.lastDrag) root.updateTarget(root.lastDrag)
    }

    function finishDrag(ev) {
        var t = root.target;
        var m = root.monitor;
        var address = root.dragAddress;
        var mode = root.dragMode;
        root.dragActive = false;
        root.target = null;
        root.showCard = false;
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.pendingEdge = "";
        dwellTimer.stop();
        if (!root.dragSnappable)
            return;
        if (!t || !m) {
            if (mode === "move" && wl.get("snapping.restoreSize", true))
                root.restoreAfterDrag(address, ev);
            else
                root.forgetSize(address);
            return;
        }
        if (t.type === "max") {
            root.maximize(address);
        } else if (t.type === "vmax") {
            root.placeOuter(address, t.rect);
            // Hyprland finishes a border drag after the drop and can leave the
            // window a pixel taller: with no gap below, under the taskbar.
            // Place it again once it has.
            root.stretchAgain = { address: address, rect: t.rect };
            stretchTimer.restart();
        } else if (t.rect) {
            // Fitted beside other windows: no layout for snap assist to fill.
            root.placeOuter(address, t.rect, m.workspaceId);
        } else {
            root.targetAddress = address;
            root.chooseZone(t.layout, t.zone);
        }
    }

    property var stretchAgain: null
    Timer {
        id: stretchTimer
        interval: 150
        onTriggered: {
            var s = root.stretchAgain;
            root.stretchAgain = null;
            if (s && !root.dragActive)
                root.placeOuter(s.address, s.rect);
        }
    }

    function forgetSize(address) {
        if (!root.restoreSizes[address])
            return;
        var sizes = Object.assign({}, root.restoreSizes);
        delete sizes[address];
        root.restoreSizes = sizes;
    }

    // ---------- Picker and snap assist ----------

    // "" hidden, "picker" (Super + Z), "assist" (choosing windows for the rest).
    property string mode: ""
    readonly property bool opened: mode !== ""
    property string targetAddress: ""
    property int hoverLayout: -1
    property int hoverZone: -1
    property int assistLayout: -1
    property var assistZones: []
    property var placedAddresses: []
    readonly property int assistZone: assistZones.length > 0 ? assistZones[0] : -1
    property var candidates: []

    readonly property int cardPadding: 14
    readonly property int thumbGap: 12
    readonly property int thumbHeight: 64

    function thumbWidth() {
        var aspect = root.monitor ? root.monitor.w / root.monitor.h : 16 / 9;
        return Math.round(root.thumbHeight * Math.max(1.3, Math.min(aspect, 2.4)));
    }

    // The picker card, in coordinates local to the monitor.
    function cardRect() {
        var n = root.layouts.length;
        var w = 2 * root.cardPadding + n * root.thumbWidth() + (n - 1) * root.thumbGap;
        var h = 2 * root.cardPadding + root.thumbHeight;
        var mw = root.monitor ? root.monitor.w : w;
        var top = root.monitor ? root.monitor.reserved[1] : 0;
        return { x: Math.round((mw - w) / 2), y: top + 12, w: w, h: h };
    }

    function thumbRect(i) {
        var c = root.cardRect();
        var tw = root.thumbWidth();
        return { x: c.x + root.cardPadding + i * (tw + root.thumbGap), y: c.y + root.cardPadding, w: tw, h: root.thumbHeight };
    }

    function zoneThumbRect(layoutIndex, zoneIndex, tw, th) {
        var inset = 4, half = 1.5;
        var iw = tw - 2 * inset, ih = th - 2 * inset;
        var z = root.layouts[layoutIndex][zoneIndex];
        var x1 = inset + z[0] * iw + (z[0] > 0.001 ? half : 0);
        var x2 = inset + (z[0] + z[2]) * iw - (z[0] + z[2] < 0.999 ? half : 0);
        var y1 = inset + z[1] * ih + (z[1] > 0.001 ? half : 0);
        var y2 = inset + (z[1] + z[3]) * ih - (z[1] + z[3] < 0.999 ? half : 0);
        return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
    }

    // Which thumbnail zone is under a monitor-local point. While dragging, a
    // generous box around the card counts, so the pointer can sit just above it.
    function hitTest(lx, ly) {
        for (var i = 0; i < root.layouts.length; i++) {
            var t = root.thumbRect(i);
            if (lx < t.x - 4 || lx >= t.x + t.w + 4 || ly < t.y - 4 || ly >= t.y + t.h + 4)
                continue;
            for (var j = 0; j < root.layouts[i].length; j++) {
                var z = root.zoneThumbRect(i, j, t.w, t.h);
                if (lx >= t.x + z.x - 3 && lx < t.x + z.x + z.w + 3 && ly >= t.y + z.y - 3 && ly < t.y + z.y + z.h + 3)
                    return { layout: i, zone: j };
            }
        }
        return { layout: -1, zone: -1 };
    }

    function toplevelFor(address) {
        var all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (var i = 0; i < all.length; i++)
            if ("0x" + String(all[i].address) === address)
                return all[i];
        return null;
    }

    property var iconCache: ({})
    function iconPathOf(icon) {
        icon = String(icon || "");
        if (icon.charAt(0) === "/")
            return "file://" + icon;
        return (icon && Quickshell.iconPath(icon, true)) || Quickshell.iconPath("application-x-executable", true);
    }

    function iconFor(client) {
        var cls = String(client.class || client.initialClass || "").toLowerCase();
        if (Object.prototype.hasOwnProperty.call(root.iconCache, cls))
            return root.iconCache[cls];
        var entries = DesktopEntries.applications ? DesktopEntries.applications.values : [];
        var found = null;
        for (var i = 0; cls && i < entries.length; i++) {
            var e = entries[i];
            if (String(e.id || "").toLowerCase().replace(/\.desktop$/, "") === cls || String(e.startupClass || "").toLowerCase() === cls) {
                found = e;
                break;
            }
        }
        if (found || (cls && Quickshell.iconPath(cls, true))) {
            var path = root.iconPathOf(found ? (found.icon || cls) : cls);
            root.iconCache[cls] = path;
            return path;
        }
        // A window whose class names no app (or that has none, as some X11
        // apps don't) is matched to its app by the process behind it, as the
        // taskbar does (TaskbarModel.entryForProcess).
        var pid = Number(client.pid) || 0;
        var info = pid > 0 ? root.processInfo[pid] : undefined;
        if (pid > 0 && info === undefined) {
            Qt.callLater(root.wantProcess, pid);
            return root.iconPathOf("");
        }
        var commands = [];
        for (var j = 0; j < entries.length; j++)
            commands.push({ id: entries[j].id, name: entries[j].name, command: entries[j].command || [], workingDirectory: entries[j].workingDirectory || "" });
        var id = info ? Model.entryForProcess(info, commands, client.title, Quickshell.env("HOME")) : "";
        var entry = id ? DesktopEntries.byId(id) : null;
        return root.iconPathOf(entry ? entry.icon : "");
    }

    // pid -> { exe, cwd, args }, read from /proc once per process.
    property var processInfo: ({})
    property var processWanted: []

    function wantProcess(pid) {
        if (root.processInfo[pid] !== undefined || root.processWanted.indexOf(pid) >= 0)
            return;
        root.processWanted = root.processWanted.concat([pid]);
        processTimer.restart();
    }

    Timer {
        id: processTimer
        interval: 30
        onTriggered: {
            if (processReader.running || root.processWanted.length === 0)
                return;
            processReader.pids = root.processWanted.map(String);
            root.processWanted = [];
            processReader.running = true;
        }
    }

    Process {
        id: processReader
        property var pids: []
        // pid, executable and working folder, then the arguments split by \x1f.
        command: ["sh", "-c", "for p in \"$@\"; do printf '%s\\t%s\\t%s\\t' \"$p\" \"$(readlink /proc/$p/exe 2>/dev/null)\" \"$(readlink /proc/$p/cwd 2>/dev/null)\"; tr '\\0' '\\037' < /proc/$p/cmdline 2>/dev/null; echo; done", "sh"].concat(pids)
        stdout: StdioCollector {
            onStreamFinished: {
                var next = Object.assign({}, root.processInfo);
                var lines = String(text).split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var f = lines[i].split("\t");
                    if (f.length < 4 || !(Number(f[0]) > 0))
                        continue;
                    next[Number(f[0])] = { exe: f[1], cwd: f[2], args: f.slice(3).join("\t").split("\x1f").filter(function(a) { return a !== ""; }) };
                }
                // A process that has gone, or can't be read, is not asked about again.
                for (var j = 0; j < processReader.pids.length; j++)
                    if (next[Number(processReader.pids[j])] === undefined)
                        next[Number(processReader.pids[j])] = {};
                root.processInfo = next;
                if (root.processWanted.length > 0)
                    processTimer.restart();
            }
        }
    }

    function isSnappable(c) {
        if (!c || !c.address || c.mapped === false || c.hidden === true)
            return false;
        var ws = c.workspace || {};
        return Number(ws.id) > 0 || String(ws.name || "") === "special:minimized";
    }

    // Whether a window belongs to a workspace: it is on it, or was minimized
    // from it (Omarchy tags a minimized window omarchy-minimized-from-<id>).
    function onWorkspace(c, wsId) {
        if (Number(c.workspace && c.workspace.id) === wsId)
            return true;
        var tags = c.tags || [];
        return String(c.workspace && c.workspace.name || "") === "special:minimized"
            && tags.indexOf("omarchy-minimized-from-" + wsId) !== -1;
    }

    // Snap assist offers the windows of the workspace being snapped on, as
    // Windows offers those of the virtual desktop you are on.
    // A tabbed window (a Hyprland group) is offered once, as the tab in front:
    // the one focused last, since picking a tab focuses it. A group with a
    // placed tab is placed.
    function tabsOf(c) {
        var g = c.grouped || [];
        return g.length > 1 ? g : [c.address];
    }

    function refreshCandidates() {
        var list = [];
        var wsId = root.monitor ? root.monitor.workspaceId : -1;
        var front = {};  // first tab's address -> the tab in front so far
        for (var i = 0; i < root.clients.length; i++) {
            var c = root.clients[i];
            var tabs = root.tabsOf(c);
            var placed = tabs.some(function(a) {
                return root.placedAddresses.indexOf(a) !== -1;
            });
            if (!root.isSnappable(c) || placed || !root.onWorkspace(c, wsId))
                continue;
            var key = tabs[0];
            if (!front[key] || Number(c.focusHistoryID) < Number(front[key].focusHistoryID))
                front[key] = c;
        }
        for (var k in front)
            list.push(front[k]);
        list.sort(function(a, b) {
            return Number(a.focusHistoryID) - Number(b.focusHistoryID);
        });
        root.candidates = list;
    }

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.requestSnapshot("picker");
    }

    // Shell overlay contract (omarchy-shell shell summon <id>).
    function open(payload) {
        if (!root.opened)
            root.requestSnapshot("picker");
    }

    function close() {
        if (root.mode === "")
            return;
        root.mode = "";
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.assistLayout = -1;
        root.assistZones = [];
        root.placedAddresses = [];
        root.candidates = [];
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.pluginId);
        if (root.focusAfter !== "")
            focusTimer.restart();
    }

    function startPicker() {
        var active = root.activeIpc;
        if (!active || !active.address || Number(active.fullscreen) > 0)
            return;
        var m = root.monitorById(active.monitor);
        if (!m)
            return;
        root.monitor = m;
        root.targetAddress = active.address;
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.mode = "picker";
    }

    // The first window is placed: snap it, then offer windows for the rest.
    function chooseZone(layoutIndex, zoneIndex) {
        if (layoutIndex < 0 || zoneIndex < 0 || !root.targetAddress || !root.monitor) {
            root.close();
            return;
        }
        root.placedAddresses = [root.targetAddress];
        root.placeInZone(root.targetAddress, root.monitor, layoutIndex, zoneIndex);
        var rest = [];
        for (var j = 0; j < root.layouts[layoutIndex].length; j++)
            if (j !== zoneIndex)
                rest.push(j);
        root.assistLayout = layoutIndex;
        root.assistZones = rest;
        root.hoverLayout = -1;
        root.hoverZone = -1;
        root.refreshCandidates();
        if (!root.assistEnabled || root.assistZones.length === 0 || root.candidates.length === 0) {
            root.close();
            return;
        }
        root.mode = "assist";
    }

    function assistPick(address) {
        if (root.assistZone < 0)
            return;
        root.placedAddresses = root.placedAddresses.concat([address]);
        root.placeInZone(address, root.monitor, root.assistLayout, root.assistZone);
        root.assistZones = root.assistZones.slice(1);
        root.refreshCandidates();
        if (root.assistZones.length === 0 || root.candidates.length === 0)
            root.close();
    }

    function assistSkip() {
        root.assistZones = root.assistZones.slice(1);
        if (root.assistZones.length === 0)
            root.close();
    }

    // ---------- Hyprland state ----------

    property string snapshotReason: ""
    property var activeIpc: null

    function requestSnapshot(reason) {
        root.snapshotReason = reason;
        if (!snapshotProc.running)
            snapshotProc.running = true;
    }

    Process {
        id: snapshotProc
        command: ["sh", "-c", "hyprctl -j monitors; printf '\\n@@OWL@@\\n'; hyprctl -j clients; printf '\\n@@OWL@@\\n'; hyprctl -j activewindow"]
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = String(text).split("\n@@OWL@@\n");
                var s = parts.map(function(p) {
                    try {
                        return JSON.parse(p);
                    } catch (e) {
                        return null;
                    }
                });
                root.monitorsIpc = s[0] || [];
                root.monitors = root.monitorsIpc.map(root.monitorFromIpc);
                root.clients = s[1] || [];
                root.activeIpc = s[2] && s[2].address ? s[2] : null;
                if (root.snapshotReason === "picker") {
                    root.startPicker();
                } else if (root.snapshotReason === "drag" && root.dragActive) {
                    var c = root.clientByAddress(root.dragAddress);
                    // Only floating windows snap; a tiled drag belongs to the layout.
                    root.dragSnappable = !!c && c.floating === true && Number(c.fullscreen) === 0
                        && Number(c.workspace && c.workspace.id) > 0;
                    root.snapshotReady = true;
                    if (root.lastDrag)
                        root.updateTarget(root.lastDrag);
                }
            }
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event)
                return;
            if (event.name === "configreloaded") {
                reloadOptions.restart();
                return;
            }
            if (event.name !== "custom")
                return;
            var data = String(event.data);
            if (data.indexOf("windows-like:") === 0)
                root.handleDragEvent(data.slice("windows-like:".length));
            else if (data === "windows-like-toggle")
                root.toggle();
        }
    }

    IpcHandler {
        target: "windowslike"
        function toggle(): string {
            root.toggle();
            return "ok";
        }
        function close(): string {
            root.close();
            return "ok";
        }
        // Drag-to-snap: `drag on`, `drag off`, or `drag status`.
        function drag(state: string): string {
            if (state === "on" || state === "off")
                root.saveSetting("dragToSnap", state === "on");
            else if (state !== "status")
                return "expected on, off, or status";
            return root.dragEnabled ? "on" : "off";
        }
        // Snap assist after a snap: `assist on`, `assist off`, or `assist status`.
        function assist(state: string): string {
            if (state === "on" || state === "off")
                root.saveSetting("snapAssist", state === "on");
            else if (state !== "status")
                return "expected on, off, or status";
            return root.assistEnabled ? "on" : "off";
        }
        // Pick a zone in the open picker, e.g. `choose 0 0` = left half.
        function choose(layout: int, zone: int): string {
            if (root.mode !== "picker")
                return "picker not open";
            if (layout < 0 || layout >= root.layouts.length || zone < 0 || zone >= root.layouts[layout].length)
                return "no such zone";
            root.chooseZone(layout, zone);
            return "ok";
        }
        // What the plugin last saw, for tests and bug reports.
        function state(): string {
            return JSON.stringify({
                dragActive: root.dragActive,
                dragMode: root.dragMode,
                snappable: root.dragSnappable,
                target: root.target,
                showCard: root.showCard,
                mode: root.mode,
                monitors: root.monitors.length,
                borderSize: root.borderSize,
                gapsOut: root.gapsOut,
                gapsIn: root.gapsIn,
                barHeight: root.barHeight,
                tabBarHeight: root.tabBarHeight,
                hasTitleBars: root.hasTitleBars
            });
        }
    }

    // ---------- Settings ----------

    // Saved in ~/.config/omarchy/shell.json as { "id": "io.github.neilgraham.windows-like",
    // "dragToSnap": true|false, "snapAssist": true|false }. Both default to on.
    property var settingsEntry: null
    property var overrides: ({})

    function setting(key) {
        if (Object.prototype.hasOwnProperty.call(root.overrides, key))
            return root.overrides[key];
        if (root.settingsEntry && typeof root.settingsEntry[key] === "boolean")
            return root.settingsEntry[key];
        return true;
    }
    readonly property bool dragEnabled: { root.overrides; root.settingsEntry; return root.setting("dragToSnap"); }
    readonly property bool assistEnabled: { root.overrides; root.settingsEntry; return root.setting("snapAssist") && wl.get("snapping.assist", true); }

    function saveSetting(key, value) {
        var o = Object.assign({}, root.overrides);
        o[key] = value;
        root.overrides = o;
        if (!root.shell || typeof root.shell.updateEntryInline !== "function") {
            console.warn(root.pluginId + ": can't save " + key + "; it lasts until the shell restarts");
            return;
        }
        var settings = Object.assign({}, root.settingsEntry || {});
        delete settings.id;
        settings[key] = value;
        root.shell.updateEntryInline(root.pluginId, settings);
    }

    function loadSettings(raw) {
        try {
            var config = JSON.parse(raw);
            var plugins = Array.isArray(config.plugins) ? config.plugins : [];
            var entry = null;
            for (var i = 0; i < plugins.length; i++)
                if (plugins[i] && plugins[i].id === root.pluginId)
                    entry = plugins[i];
            root.settingsEntry = entry;
            root.overrides = ({});
        } catch (e) {
            console.warn(root.pluginId + ": could not read shell.json: " + e);
        }
    }

    FileView {
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.loadSettings(text())
        onFileChanged: reload()
    }

    // ---------- UI ----------

    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // The outer box the preview shows, in global coordinates, or null.
    readonly property var previewRect: {
        if (root.mode === "assist" || !root.monitor)
            return null;
        if (root.mode === "picker")
            return root.hoverLayout >= 0 && root.hoverZone >= 0 ? root.zoneOuterRect(root.monitor, root.hoverLayout, root.hoverZone) : null;
        var t = root.target;
        if (!root.dragActive || !t)
            return null;
        if (t.type === "zone")
            return t.rect || root.zoneOuterRect(root.monitor, t.layout, t.zone);
        if (t.type === "vmax")
            return t.rect;
        var m = root.monitor;
        return { x: m.x + m.reserved[0] + root.gapsOut, y: m.y + m.reserved[1] + root.gapsOut,
                 w: m.w - m.reserved[0] - m.reserved[2] - 2 * root.gapsOut, h: m.h - m.reserved[1] - m.reserved[3] - 2 * root.gapsOut };
    }
    readonly property bool dragOverlay: root.dragActive && (root.showCard || root.previewRect !== null)
    readonly property bool cardVisible: root.mode === "picker" || (root.dragActive && root.showCard)

    // Made on first use and kept, hidden between uses, so a drag doesn't wait
    // on building it.
    property bool overlayMade: false
    onOpenedChanged: if (root.opened) root.overlayMade = true
    onDragOverlayChanged: if (root.dragOverlay) root.overlayMade = true
    Loader {
        active: root.overlayMade && root.monitor !== null
        sourceComponent: overlayComponent
    }

    component PlainText: Text {
        textFormat: Text.PlainText
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
    }

    Component {
        id: overlayComponent

        PanelWindow { // qmllint disable uncreatable-type
            id: surface

            screen: {
                var screens = Quickshell.screens;
                for (var i = 0; i < screens.length; i++)
                    if (screens[i].name === root.monitor.name)
                        return screens[i];
                return screens.length > 0 ? screens[0] : null;
            }
            anchors {
                top: true
                right: true
                bottom: true
                left: true
            }
            // Mapped while in use, and while its pieces fade out.
            visible: root.opened || root.dragOverlay || landing.opacity > 0 || card.opacity > 0 || scrim.opacity > 0
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "windows-like"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            // While a window is being dragged the overlay must not take the pointer.
            mask: root.opened ? null : noInput

            Region {
                id: noInput
            }

            Item {
                id: content
                anchors.fill: parent
                focus: true
                Keys.onEscapePressed: root.close()
                Keys.onPressed: function(event) {
                    if (root.mode === "assist" && event.key === Qt.Key_Tab) {
                        root.assistSkip();
                        event.accepted = true;
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.opened
                    onClicked: root.close()
                }

                // Fades start once the surface is on screen, so none of
                // their first frames are spent mapping it.
                readonly property bool onScreen: surface.backingWindowVisible

                Rectangle {
                    id: scrim
                    anchors.fill: parent
                    visible: opacity > 0
                    color: "black"
                    opacity: root.mode === "assist" && content.onScreen ? 0.35 : 0
                    Behavior on opacity { NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                }

                // Where the window will land. It appears where it points and
                // fades; it glides only from one place to the next, and fades
                // out where it was as the window takes its place.
                Rectangle {
                    id: landing
                    property var r: null
                    readonly property var target: root.previewRect
                    onTargetChanged: if (target) r = target
                    visible: opacity > 0 && r !== null
                    opacity: target !== null && content.onScreen ? 1 : 0
                    x: r ? r.x - root.monitor.x : 0
                    y: r ? r.y - root.monitor.y : 0
                    width: r ? r.w : 0
                    height: r ? r.h : 0
                    radius: Style.cornerRadius
                    color: root.withAlpha(Commons.Color.accent, 0.18)
                    border.color: root.withAlpha(Commons.Color.accent, 0.8)
                    border.width: 2

                    Behavior on opacity { NumberAnimation { duration: root.duration(landing.target ? 120 : 160); easing.type: Easing.OutCubic } }
                    Behavior on x { enabled: landing.opacity > 0; NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: landing.opacity > 0; NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                    Behavior on width { enabled: landing.opacity > 0; NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                    Behavior on height { enabled: landing.opacity > 0; NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                }

                // ----- Layout picker card -----
                // Drops in from just above its place as it fades, like Windows
                // 11's snap layouts.
                Rectangle {
                    id: card
                    readonly property var r: root.cardRect()
                    visible: opacity > 0
                    opacity: root.cardVisible && content.onScreen ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.duration(root.cardVisible ? 160 : 110); easing.type: Easing.OutCubic } }
                    transform: Translate {
                        y: (card.opacity - 1) * 12
                    }
                    x: r.x
                    y: r.y
                    width: r.w
                    height: r.h
                    radius: Style.cornerRadius + 4
                    color: Commons.Color.popups.background
                    border.color: Commons.Color.popups.border
                    border.width: 1

                    MouseArea {
                        anchors.fill: parent
                    }

                    Repeater {
                        model: root.layouts.length

                        Rectangle {
                            id: thumb
                            required property int index
                            readonly property var r: root.thumbRect(index)
                            x: r.x - card.r.x
                            y: r.y - card.r.y
                            width: r.w
                            height: r.h
                            radius: Style.cornerRadius
                            color: root.withAlpha(Commons.Color.popups.text, 0.06)
                            border.color: root.withAlpha(Commons.Color.popups.text, root.hoverLayout === index ? 0.5 : 0.18)
                            border.width: 1

                            Repeater {
                                model: root.layouts[thumb.index].length

                                Rectangle {
                                    id: zone
                                    required property int index
                                    readonly property var zr: root.zoneThumbRect(thumb.index, index, thumb.width, thumb.height)
                                    readonly property bool hot: root.hoverLayout === thumb.index && root.hoverZone === index
                                    x: zr.x
                                    y: zr.y
                                    width: zr.w
                                    height: zr.h
                                    radius: Math.max(2, Style.cornerRadius / 2)
                                    color: hot ? Commons.Color.accent : root.withAlpha(Commons.Color.popups.text, 0.22)

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -2
                                        enabled: root.mode === "picker"
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: {
                                            root.hoverLayout = thumb.index;
                                            root.hoverZone = zone.index;
                                        }
                                        onExited: {
                                            if (root.hoverLayout === thumb.index && root.hoverZone === zone.index) {
                                                root.hoverLayout = -1;
                                                root.hoverZone = -1;
                                            }
                                        }
                                        onClicked: root.chooseZone(thumb.index, zone.index)
                                    }
                                }
                            }
                        }
                    }
                }

                // ----- Snap assist -----
                Repeater {
                    model: root.mode === "assist" ? root.placedAddresses.length : 0

                    Rectangle {
                        required property int index
                        readonly property var r: {
                            var all = root.layouts[root.assistLayout];
                            var filled = [];
                            for (var j = 0; j < all.length; j++)
                                if (root.assistZones.indexOf(j) === -1)
                                    filled.push(j);
                            return index < filled.length ? root.zoneOuterRect(root.monitor, root.assistLayout, filled[index]) : null;
                        }
                        visible: r !== null
                        x: r ? r.x - root.monitor.x : 0
                        y: r ? r.y - root.monitor.y : 0
                        width: r ? r.w : 0
                        height: r ? r.h : 0
                        color: "transparent"
                        radius: Style.cornerRadius
                        border.color: root.withAlpha(Commons.Color.popups.text, 0.35)
                        border.width: 1
                    }
                }

                Rectangle {
                    id: assistPanel
                    readonly property var r: root.mode === "assist" && root.assistZone >= 0
                        ? root.zoneOuterRect(root.monitor, root.assistLayout, root.assistZone) : null
                    visible: r !== null
                    opacity: visible && content.onScreen ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.duration(150); easing.type: Easing.OutCubic } }
                    x: r ? r.x - root.monitor.x : 0
                    y: r ? r.y - root.monitor.y : 0
                    width: r ? r.w : 0
                    height: r ? r.h : 0
                    radius: Style.cornerRadius + 4
                    color: root.withAlpha(Commons.Color.popups.background, 0.94)
                    border.color: Commons.Color.accent
                    border.width: 2

                    MouseArea {
                        anchors.fill: parent
                    }

                    PlainText {
                        id: assistTitle
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 14
                        text: "Choose a window for this space · Tab to skip · Esc to finish"
                        color: root.withAlpha(Commons.Color.popups.text, 0.75)
                        elide: Text.ElideRight
                    }

                    GridView {
                        id: grid
                        readonly property int columns: Math.max(1, Math.floor(width / 210))
                        anchors.top: assistTitle.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 10
                        clip: true
                        cellWidth: Math.floor(width / columns)
                        cellHeight: Math.round(cellWidth * 0.62) + 34
                        model: root.candidates
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            id: cell
                            required property var modelData
                            width: grid.cellWidth
                            height: grid.cellHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 6
                                radius: Style.cornerRadius + 2
                                color: tileMouse.containsMouse ? root.withAlpha(Commons.Color.accent, 0.2) : root.withAlpha(Commons.Color.popups.text, 0.05)
                                border.color: tileMouse.containsMouse ? Commons.Color.accent : root.withAlpha(Commons.Color.popups.text, 0.15)
                                border.width: tileMouse.containsMouse ? 2 : 1

                                Item {
                                    anchors.top: parent.top
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: label.top
                                    anchors.margins: 6
                                    clip: true

                                    ScreencopyView {
                                        id: preview
                                        readonly property var source: root.toplevelFor(cell.modelData.address)
                                        readonly property real aspect: cell.modelData.size && cell.modelData.size[1] > 0 ? cell.modelData.size[0] / cell.modelData.size[1] : 1.6
                                        anchors.centerIn: parent
                                        width: Math.min(parent.width, parent.height * aspect)
                                        height: width / aspect
                                        captureSource: source && source.wayland ? source.wayland : null
                                        live: false
                                        paintCursor: false
                                    }

                                    // Windows with no capture (e.g. minimized) show their icon.
                                    Image {
                                        anchors.centerIn: parent
                                        visible: !preview.hasContent
                                        width: Math.min(48, parent.height * 0.6)
                                        height: width
                                        source: root.iconFor(cell.modelData)
                                        sourceSize.width: 96
                                        sourceSize.height: 96
                                    }
                                }

                                Row {
                                    id: label
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 8
                                    height: 20
                                    spacing: 6

                                    Image {
                                        width: 18
                                        height: 18
                                        anchors.verticalCenter: parent.verticalCenter
                                        source: root.iconFor(cell.modelData)
                                        sourceSize.width: 36
                                        sourceSize.height: 36
                                    }

                                    PlainText {
                                        width: label.width - 24
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String(cell.modelData.title || cell.modelData.class || "Window")
                                        color: Commons.Color.popups.text
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: tileMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.assistPick(cell.modelData.address)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
