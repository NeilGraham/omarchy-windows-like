"""Snapping fills the room beside full-height windows: next to a snapped
window that was resized, or on either side of one stretched down the middle
(three side by side), instead of taking exactly half.

Usage: python -I tests/test_snap_fill.py native/drag-events/drag-events.so [artifacts-dir]
"""
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-snap-fill')

GAPS_OUT, GAPS_IN, BORDER, BAR = 10, 5, 2, 30
# Snapped windows meet each other and the screen's edges (snapping.gaps off).
SNAP_OUT, GAP = 0, 0


def wait_for(fn, timeout=4, what='condition'):
  deadline = time.time() + timeout
  while time.time() < deadline:
    v = fn()
    if v:
      return v
    time.sleep(.1)
  raise AssertionError(f'timed out waiting for {what}')


with Nested(artifacts) as n:
  n.ctl('eval', 'hl.config({ general = { gaps_in = %d, gaps_out = %d, border_size = %d } })' % (GAPS_IN, GAPS_OUT, BORDER))
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  n.ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "omarchy-floating-workspace" } } })')
  windows = {}
  for name in ('a', 'b', 'c'):
    w = n.open_window(name)
    windows[name] = w['address']
    n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{w["address"]}" }})')
  n.start_shell(HERE.parent / 'WindowsLike.qml')
  n.ipc('assist', 'off')
  monitor = json.loads(n.ctl('monitors', '-j'))[0]
  width, height = monitor['width'] / monitor['scale'], monitor['height'] / monitor['scale']
  area = (SNAP_OUT, SNAP_OUT, width - 2 * SNAP_OUT, height - 2 * SNAP_OUT)
  left_edge, right_edge = area[0], round(area[0] + area[2])

  def outer(addr):
    c = n.client(addr)
    return (c['at'][0] - BORDER, c['at'][1] - BAR - BORDER, c['at'][0] + c['size'][0] + BORDER, c['at'][1] + c['size'][1] + BORDER)

  def place(addr, x1, y1, x2, y2):
    """Puts a window's outer box (title bar and border included) at x1,y1-x2,y2."""
    n.ctl('dispatch', f'hl.dsp.window.move({{ x = {x1 + BORDER}, y = {y1 + BORDER + BAR}, window = "address:{addr}" }})')
    n.ctl('dispatch', f'hl.dsp.window.resize({{ x = {x2 - x1 - 2 * BORDER}, y = {y2 - y1 - 2 * BORDER - BAR}, relative = false, window = "address:{addr}" }})')
    n.ctl('dispatch', f'hl.dsp.window.move({{ x = {x1 + BORDER}, y = {y1 + BORDER + BAR}, window = "address:{addr}" }})')
    time.sleep(.3)

  def park(addr):
    """Out of the way: small, and not full height."""
    place(addr, round(width / 2) - 150, 200, round(width / 2) + 150, 400)

  def snap(addr, side):
    # On top, so the drag grabs this window's title bar and not one over it.
    n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{addr}" }})')
    n.ctl('dispatch', f'hl.dsp.window.alter_zorder({{ mode = "top", window = "address:{addr}" }})')
    time.sleep(.2)
    c = n.client(addr)
    grab = (c['at'][0] + 100, c['at'][1] - 15)
    before = outer(addr)
    n.drag(grab, (0 if side == 'left' else round(width) - 1, round(height / 2)))
    return wait_for(lambda: (lambda o: o if o != before else None)(outer(addr)), what=f'{addr} to snap {side}')

  def near(a, b, slack=1):
    return all(abs(x - y) <= slack for x, y in zip(a, b))

  top, bottom = area[1], round(area[1] + area[3])

  # 1. A is snapped left, then made wider; B snapped right fills the rest.
  park(windows['c'])
  park(windows['b'])
  snap(windows['a'], 'left')
  a_right = round(area[0] + area[2] * 0.6)
  place(windows['a'], left_edge, top, a_right, bottom)
  b = snap(windows['b'], 'right')
  assert near(b, (a_right + GAP, top, right_edge, bottom)), ('B should fill beside the widened A', b, a_right)
  n.capture('fill-beside-resized')
  print('PASS: snapping beside a resized snapped window fills the rest', flush=True)

  # 2. C stretched down the middle: A and B snapped to the sides fill around it.
  c1, c2 = round(width * 0.35), round(width * 0.65)
  place(windows['c'], c1, top, c2, bottom)
  park(windows['a'])
  park(windows['b'])
  a = snap(windows['a'], 'left')
  assert near(a, (left_edge, top, c1 - GAP, bottom)), ('A should fill left of C', a, c1)
  b = snap(windows['b'], 'right')
  assert near(b, (c2 + GAP, top, right_edge, bottom)), ('B should fill right of C', b, c2)
  n.capture('three-side-by-side')
  print('PASS: three windows side by side around a full-height one', flush=True)

  # 3. A window in the middle that isn't full height doesn't change a snap.
  park(windows['c'])
  park(windows['b'])
  park(windows['a'])
  half_right = round(area[0] + area[2] / 2 - GAP / 2)
  a = snap(windows['a'], 'left')
  assert near(a, (left_edge, top, half_right, bottom)), ('a plain half', a, half_right)
  print('PASS: other windows that are not full height leave the plain half', flush=True)

  # 4. Turned off, it's always the plain half.
  place(windows['c'], c1, top, c2, bottom)
  n.settings_json.write_text(json.dumps({'snapping': {'fillSpace': False}}))
  time.sleep(.6)
  park(windows['a'])
  a = snap(windows['a'], 'left')
  assert near(a, (left_edge, top, half_right, bottom)), ('fillSpace off: a plain half', a)
  print('PASS: snapping.fillSpace = false keeps plain halves', flush=True)
  print('ALL PASS', flush=True)
