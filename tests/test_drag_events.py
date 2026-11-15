"""The drag-events plugin reports title-bar moves and border resizes.

Usage: python -I tests/test_drag_events.py native/drag-events/drag-events.so
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-drag-events')


def parse(event):
  kind, mode, address, cx, cy, x, y, w, h = event.split(':', 1)[1].split('|')
  return {'kind': kind, 'mode': mode, 'address': address, 'cursor': (int(cx), int(cy)), 'box': (int(x), int(y), int(w), int(h))}


with Nested(artifacts) as n:
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  window = n.open_window()
  addr = window['address']

  # 1. A title-bar drag (Omarchy's title bars swallow the button).
  n.events.clear()
  sx = window['at'][0] + 150
  sy = window['at'][1] - 15
  n.drag((sx, sy), (sx + 200, sy + 100))
  ev = [parse(e) for e in n.custom()]
  kinds = [e['kind'] for e in ev]
  assert kinds and kinds[0] == 'start' and kinds[-1] == 'end', kinds
  assert kinds.count('start') == 1 and kinds.count('end') == 1, kinds
  assert 'move' in kinds, kinds
  assert all(e['mode'] == 'move' and e['address'] == addr for e in ev), ev
  end = ev[-1]
  assert abs(end['cursor'][0] - (sx + 200)) <= 2 and abs(end['cursor'][1] - (sy + 100)) <= 2, end
  after = n.client(addr)
  print('box', end['box'], 'hyprctl at/size', after['at'], after['size'])
  assert (end['box'][0], end['box'][1]) == tuple(after['at']), (end, after)
  print(f'PASS: title-bar drag reported start/{kinds.count("move")} moves/end', flush=True)

  # 2. A plain click on the title bar reports nothing.
  n.events.clear()
  w = n.client(addr)
  n.pointer([f"move {w['at'][0] + 150} {w['at'][1] - 15}", 'wait 100', 'down', 'wait 80', 'up', 'wait 400'])
  assert not n.custom(), n.custom()
  print('PASS: a click reports no drag', flush=True)

  # 3. A border resize (bottom-right corner).
  n.events.clear()
  w = n.client(addr)
  cx = w['at'][0] + w['size'][0] + 3
  cy = w['at'][1] + w['size'][1] + 3
  n.drag((cx, cy), (cx + 80, cy + 60))
  ev = [parse(e) for e in n.custom()]
  kinds = [e['kind'] for e in ev]
  assert kinds and kinds[0] == 'start' and kinds[-1] == 'end', kinds
  assert all(e['mode'] == 'resize' for e in ev), ev
  after = n.client(addr)
  assert after['size'][0] > w['size'][0] + 40, (w, after)
  print('PASS: border resize reported as resize', flush=True)

  # 4. Unloading cleanly, with the compositor still alive.
  n.ctl('plugin', 'unload', str(plugin))
  assert n.compositor.poll() is None
  print('PASS: unload', flush=True)
