"""Snapped, stretched and maximized windows stay clear of a taskbar at the
bottom (any layer surface that reserves space, as Omarchy's bar does), and
the snapping settings switch behaviours off.

Usage: python -I tests/test_taskbar_space.py native/drag-events/drag-events.so [artifacts-dir]
"""
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-taskbar-space')

TASKBAR, GAPS_OUT, BORDER, BAR = 44, 10, 2, 30


def wait_for(fn, timeout=4, what='condition'):
  deadline = time.time() + timeout
  while time.time() < deadline:
    v = fn()
    if v:
      return v
    time.sleep(.1)
  raise AssertionError(f'timed out waiting for {what}')


with Nested(artifacts) as n:
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  n.ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "omarchy-floating-workspace" } } })')
  w = n.open_window('first')
  addr = w['address']
  n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{addr}" }})')
  n.start_shell(HERE.parent / 'WindowsLike.qml', env={'OWL_TEST_TASKBAR': str(TASKBAR)})
  n.ipc('assist', 'off')
  monitor = wait_for(lambda: (lambda m: m if m['reserved'][3] == TASKBAR else None)(json.loads(n.ctl('monitors', '-j'))[0]),
                     what='the taskbar to reserve its space')
  height = monitor['height'] / monitor['scale']
  bottom_limit = round(height - TASKBAR - GAPS_OUT)  # the lowest a window's outer edge may reach

  def reset():
    n.ctl('dispatch', f'hl.dsp.window.fullscreen({{ mode = "maximized", action = "unset", window = "address:{addr}" }})')
    n.ctl('dispatch', f'hl.dsp.window.resize({{ x = 500, y = 340, relative = false, window = "address:{addr}" }})')
    n.ctl('dispatch', f'hl.dsp.window.move({{ x = 300, y = 150, window = "address:{addr}" }})')
    time.sleep(.3)
    return n.client(addr)

  def outer_bottom(c):
    return c['at'][1] + c['size'][1] + BORDER

  def grab(c):
    return (c['at'][0] + 120, c['at'][1] - 15)

  # Halves and quarters end above the taskbar.
  for name, target in [('left half', (0, 300)), ('bottom-left quarter', (30, round(height) - 1))]:
    c = reset()
    n.drag(grab(c), target)
    c = wait_for(lambda: (lambda c: c if c['size'] != [500, 340] else None)(n.client(addr)), what=name)
    assert outer_bottom(c) == bottom_limit, (name, outer_bottom(c), bottom_limit)
    print(f'PASS: {name} ends above the taskbar', flush=True)

  # Stretching by the bottom border, to the taskbar's edge, stops above it.
  c = reset()
  x = c['at'][0] + c['size'][0] // 2
  n.drag((x, outer_bottom(c) + 3), (x, round(height) - TASKBAR - 2))
  c = wait_for(lambda: (lambda c: c if c['size'][1] > 400 else None)(n.client(addr)), what='full-height stretch')
  # The shell asks for exactly bottom_limit; after a border drag Hyprland can
  # land a pixel lower, still inside the gap and clear of the taskbar.
  assert 0 <= outer_bottom(c) - bottom_limit <= 1 and c['at'][1] == GAPS_OUT + BORDER + BAR, (c['at'], c['size'], bottom_limit)
  assert outer_bottom(c) < round(height) - TASKBAR, 'behind the taskbar'
  print('PASS: full-height stretch ends above the taskbar', flush=True)

  # Maximizing (dragging to the top) leaves the taskbar clear.
  c = reset()
  n.drag(grab(c), (c['at'][0] + 120, 0))
  c = wait_for(lambda: (lambda c: c if c['fullscreen'] == 1 else None)(n.client(addr)), what='maximize')
  assert c['at'][1] + c['size'][1] <= round(height) - TASKBAR, (c['at'], c['size'])
  print('PASS: a maximized window leaves the taskbar clear', flush=True)
  n.capture('maximized-over-taskbar')

  # Settings switch behaviours off, live.
  n.settings_json.write_text(json.dumps({'snapping': {'edges': False}}))
  time.sleep(.6)
  c = reset()
  n.drag(grab(c), (0, 300))
  time.sleep(.6)
  assert n.client(addr)['size'] == [500, 340], n.client(addr)
  print('PASS: snapping.edges = false leaves a window dropped at an edge alone', flush=True)
  n.settings_json.write_text(json.dumps({'snapping': {'edges': True}}))
  time.sleep(.6)
  c = reset()
  n.drag(grab(c), (0, 300))
  wait_for(lambda: n.client(addr)['size'] != [500, 340], what='edges back on')
  print('PASS: and turning it back on snaps again', flush=True)
  print('ALL PASS', flush=True)
