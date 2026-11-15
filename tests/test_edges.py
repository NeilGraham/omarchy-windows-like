"""Border resizing like Windows: a side resizes along one axis only, corners
along both, and the band above the title bar resizes the top.

Usage: python -I tests/test_edges.py native/drag-events/drag-events.so [artifacts-dir]
"""
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-edges')

BORDER, BAR = 2, 30
DX, DY = 60, 45  # every drag moves diagonally, so a side that resizes both ways shows it


def reset(n, addr):
  n.ctl('dispatch', f'hl.dsp.window.resize({{ x = 600, y = 400, relative = false, window = "address:{addr}" }})')
  n.ctl('dispatch', f'hl.dsp.window.move({{ x = 150, y = 180, window = "address:{addr}" }})')
  time.sleep(.3)
  return n.client(addr)


def box(c):
  x, y = c['at']
  w, h = c['size']
  return x, y, w, h


def expect(name, before, after, dx=0, dy=0, dw=0, dh=0, slack=2):
  bx, by, bw, bh = box(before)
  ax, ay, aw, ah = box(after)
  got = (ax - bx, ay - by, aw - bw, ah - bh)
  want = (dx, dy, dw, dh)
  assert all(abs(g - w) <= slack for g, w in zip(got, want)), (name, 'got dx,dy,dw,dh', got, 'want', want)
  print(f'PASS: {name}', flush=True)


with Nested(artifacts) as n:
  n.ctl('eval', f'hl.config({{ general = {{ border_size = {BORDER}, extend_border_grab_area = 8, resize_on_border = true }} }})')
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  w = n.open_window()
  addr = w['address']

  def drag_from(px, py):
    before = n.client(addr)
    n.drag((px, py), (px + DX, py + DY), steps=12)
    time.sleep(.2)
    return before, n.client(addr)

  # Sides: one axis only.
  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x - 4, y + hh // 2)
  expect('left side resizes width only', b, a, dx=DX, dw=-DX)

  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x + ww + 4, y + hh // 2)
  expect('right side resizes width only', b, a, dw=DX)

  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x + ww // 2, y + hh + 4)
  expect('bottom side resizes height only', b, a, dh=DY)

  # The band above the title bar is the top side.
  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x + ww // 2, y - BAR - BORDER - 4)
  expect('top side (above the title bar) resizes height only', b, a, dy=DY, dh=-DY)

  # Corners: both axes.
  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x + ww + 4, y + hh + 4)
  expect('bottom-right corner resizes both', b, a, dw=DX, dh=DY)

  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x - 4, y - BAR - BORDER - 4)
  expect('top-left corner (above the title bar) resizes both', b, a, dx=DX, dy=DY, dw=-DX, dh=-DY)

  # The title bar itself still moves the window.
  w = reset(n, addr)
  x, y, ww, hh = box(w)
  b, a = drag_from(x + ww // 2, y - 15)
  expect('title bar still moves', b, a, dx=DX, dy=DY, slack=8)

  # Cursor shapes, captured with the pointer drawn in: hovering the top band,
  # the left side, and the top-left corner.
  w = reset(n, addr)
  x, y, ww, hh = box(w)
  for name, (px, py) in [('cursor-top', (x + ww // 2, y - BAR - BORDER - 4)),
                         ('cursor-left', (x - 4, y + hh // 2)),
                         ('cursor-top-left', (x - 4, y - BAR - BORDER - 4))]:
    n.pointer([f'move {px - 30} {py + 60}', 'wait 50', f'move {px} {py}', 'wait 300'])
    subprocess.run(['grim', '-c', '-g', f'{px - 40},{py - 40} 80x80', str(artifacts / f'{name}.png')],
                   env=n.env, check=False)
  print('ALL PASS', flush=True)
