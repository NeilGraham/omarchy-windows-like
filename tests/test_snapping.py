"""End-to-end snapping: real pointer drags in a nested Hyprland, with the
drag-events plugin, Omarchy's title bars and WindowsLike.qml all running.

Usage: python -I tests/test_snapping.py native/drag-events/drag-events.so [artifacts-dir]
"""
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-snapping')

GAPS_OUT, GAPS_IN, BORDER, BAR = 10, 5, 2, 30


def zone(fx, fy, fw, fh):
  """The client box (at, size) a zone should give a window with a title bar."""
  ax, ay, aw, ah = AREA
  half = GAPS_IN
  x1 = ax + fx * aw + (half if fx > 0.001 else 0)
  x2 = ax + (fx + fw) * aw - (half if fx + fw < 0.999 else 0)
  y1 = ay + fy * ah + (half if fy > 0.001 else 0)
  y2 = ay + (fy + fh) * ah - (half if fy + fh < 0.999 else 0)
  l, r, t, b = round(x1), round(x2), round(y1), round(y2)
  return [l + BORDER, t + BORDER + BAR], [r - l - 2 * BORDER, b - t - 2 * BORDER - BAR]


def grab(w):
  """A point on the window's title bar."""
  return (w['at'][0] + min(150, w['size'][0] // 3), w['at'][1] - 15)


def settle(n, addr, want_at=None, want_size=None, fullscreen=None, timeout=3):
  deadline = time.time() + timeout
  while True:
    c = n.client(addr)
    ok = (want_at is None or c['at'] == want_at) and (want_size is None or c['size'] == want_size) \
      and (fullscreen is None or c['fullscreen'] == fullscreen)
    if ok or time.time() > deadline:
      return c, ok
    time.sleep(.1)


def check(name, n, addr, **want):
  c, ok = settle(n, addr, **want)
  n.capture(name)
  assert ok, (name, want, {'at': c['at'], 'size': c['size'], 'fullscreen': c['fullscreen']}, n.ipc('state'))
  print(f'PASS: {name}', flush=True)
  return c


def reset(n, addr):
  n.ctl('dispatch', f'hl.dsp.window.fullscreen({{ mode = "maximized", action = "unset", window = "address:{addr}" }})')
  n.ctl('dispatch', f'hl.dsp.window.resize({{ x = 600, y = 400, relative = false, window = "address:{addr}" }})')
  n.ctl('dispatch', f'hl.dsp.window.move({{ x = 340, y = 220, window = "address:{addr}" }})')
  time.sleep(.3)
  return n.client(addr)


with Nested(artifacts) as n:
  n.ctl('eval', 'hl.config({ general = { gaps_in = %d, gaps_out = %d, border_size = %d } })' % (GAPS_IN, GAPS_OUT, BORDER))
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  # Omarchy's floating mode tags windows on floating workspaces; title bars draw on that tag.
  n.ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "omarchy-floating-workspace" } } })')
  w = n.open_window('first')
  addr = w['address']
  n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{addr}" }})')
  n.start_shell(HERE.parent / 'WindowsLike.qml')
  WIDTH, HEIGHT = n.size()
  AREA = (GAPS_OUT, GAPS_OUT, WIDTH - 2 * GAPS_OUT, HEIGHT - 2 * GAPS_OUT)
  n.ipc('assist', 'off')
  state = n.ipc('state')
  assert state['hasTitleBars'] and state['barHeight'] == BAR and state['gapsOut'] == GAPS_OUT, state

  # Halves.
  w = reset(n, addr)
  n.drag(grab(w), (0, 400))
  at, size = zone(0, 0, .5, 1)
  check('drag to left edge -> left half', n, addr, want_at=at, want_size=size)

  w = reset(n, addr)
  n.drag(grab(w), (WIDTH - 1, 500))
  at, size = zone(.5, 0, .5, 1)
  check('drag to right edge -> right half', n, addr, want_at=at, want_size=size)

  # Corners, reached along either edge.
  w = reset(n, addr)
  n.drag(grab(w), (WIDTH - 1, 20))
  at, size = zone(.5, 0, .5, .5)
  check('drag to top-right corner -> top-right quarter', n, addr, want_at=at, want_size=size)

  w = reset(n, addr)
  n.drag(grab(w), (30, HEIGHT - 1))
  at, size = zone(0, .5, .5, .5)
  check('drag to bottom-left corner -> bottom-left quarter', n, addr, want_at=at, want_size=size)

  # Dragging a snapped window into open space gives it back its old size.
  w = n.client(addr)
  n.drag(grab(w), (640, 420))
  check('drag a snapped window away -> old size back', n, addr, want_size=[600, 400])

  # Top edge maximizes.
  w = reset(n, addr)
  n.drag(grab(w), (640, 0))
  check('drag to top edge -> maximized', n, addr, fullscreen=1)

  # The layout picker near the top: middle zone of the three-column layout.
  w = reset(n, addr)
  state = n.ipc('state')
  thumb_h = 64
  thumb_w = round(thumb_h * max(1.3, min(WIDTH / HEIGHT, 2.4)))
  card_w = 2 * 14 + 6 * thumb_w + 5 * 12
  card_x = round((WIDTH - card_w) / 2)
  thumb_x = card_x + 14 + 3 * (thumb_w + 12)
  tx = thumb_x + thumb_w // 2
  ty = 12 + 14 + thumb_h // 2
  n.drag(grab(w), (tx, 2), (tx, ty), steps=10)
  at, size = zone(1 / 3, 0, 1 / 3, 1)
  check('drop on the picker -> middle third', n, addr, want_at=at, want_size=size)

  # Top border dragged to the top of the screen -> full height, same x and width.
  w = reset(n, addr)
  x = w['at'][0] + w['size'][0] // 2
  y = w['at'][1] - BAR - BORDER - 4
  n.drag((x, y), (x, 0))
  ax, ay, aw, ah = AREA
  check('drag top border to top edge -> full height', n, addr,
        want_at=[w['at'][0], ay + BORDER + BAR], want_size=[w['size'][0], ah - 2 * BORDER - BAR])

  # Bottom border dragged to the bottom edge does the same.
  w = reset(n, addr)
  x = w['at'][0] + w['size'][0] // 2
  y = w['at'][1] + w['size'][1] + BORDER + 3
  n.drag((x, y), (x, HEIGHT - 1))
  check('drag bottom border to bottom edge -> full height', n, addr,
        want_at=[w['at'][0], ay + BORDER + BAR], want_size=[w['size'][0], ah - 2 * BORDER - BAR])

  # A drag that ends in open space leaves the window where it was dropped.
  w = reset(n, addr)
  start = grab(w)
  n.drag(start, (start[0] + 100, start[1] + 80))
  # Hyprland starts a drag a few pixels in, so the window trails the pointer slightly.
  c = check('drag in open space -> no snap', n, addr, want_size=[600, 400], fullscreen=0)
  assert abs(c['at'][0] - (w['at'][0] + 100)) <= 8 and abs(c['at'][1] - (w['at'][1] + 80)) <= 8, c['at']

  # Snap assist: snap one window left, then pick the other for the right half.
  n.ipc('assist', 'on')
  w2 = n.open_window('second')
  addr2 = w2['address']
  n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{addr2}" }})')
  w = reset(n, addr)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{addr}" }})')
  time.sleep(.2)
  w = n.client(addr)
  n.drag(grab(w), (0, 400))
  time.sleep(.5)
  state = n.ipc('state')
  assert state['mode'] == 'assist', state
  n.capture('snap assist')
  # The first tile of the assist panel in the right half.
  rx = AREA[0] + AREA[2] / 2 + GAPS_IN
  rw = AREA[0] + AREA[2] - rx
  columns = max(1, int((rw - 20) // 210))
  cell_w = (rw - 20) // columns
  n.pointer([f'move {round(rx + 10 + cell_w / 2)} {round(AREA[1] + 14 + 16 + 10 + cell_w * .31)}', 'wait 150', 'down', 'wait 60', 'up', 'wait 300'])
  at, size = zone(.5, 0, .5, 1)
  check('snap assist -> second window fills the right half', n, addr2, want_at=at, want_size=size)
  assert n.ipc('state')['mode'] == '', n.ipc('state')

  print('ALL PASS', flush=True)
