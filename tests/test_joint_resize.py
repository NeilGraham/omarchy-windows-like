"""Windows sharing an edge resize together: two halves, and the lines between
four quarters (the vertical one takes all four; a horizontal one only the
column it divides). Windows that don't share the edge stay put, and the
setting turns it off.

Usage: python -I tests/test_joint_resize.py native/drag-events/drag-events.so [artifacts-dir]
"""
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-joint')

GAPS_OUT, GAPS_IN, BORDER, BAR = 10, 5, 2, 30
DX, DY = 80, 50


with Nested(artifacts) as n:
  n.ctl('eval', f'hl.config({{ general = {{ gaps_in = {GAPS_IN}, gaps_out = {GAPS_OUT}, border_size = {BORDER}, extend_border_grab_area = 8 }} }})')
  n.load_plugin(TITLEBARS)
  n.ctl('reload')
  n.load_plugin(plugin)
  names = ['tl', 'tr', 'bl', 'br']
  win = {name: n.open_window(name)['address'] for name in names}
  monitor = json.loads(n.ctl('monitors', '-j'))[0]
  width, height = round(monitor['width'] / monitor['scale']), round(monitor['height'] / monitor['scale'])
  x0, y0, x3, y3 = GAPS_OUT, GAPS_OUT, width - GAPS_OUT, height - GAPS_OUT
  xm, ym = round((x0 + x3) / 2), round((y0 + y3) / 2)
  half = GAPS_IN

  def place(addr, x1, y1, x2, y2):
    """A window's outer box (title bar and border included) at x1,y1-x2,y2."""
    for step in ('move', 'resize', 'move'):
      if step == 'move':
        n.ctl('dispatch', f'hl.dsp.window.move({{ x = {x1 + BORDER}, y = {y1 + BORDER + BAR}, window = "address:{addr}" }})')
      else:
        n.ctl('dispatch', f'hl.dsp.window.resize({{ x = {x2 - x1 - 2 * BORDER}, y = {y2 - y1 - 2 * BORDER - BAR}, relative = false, window = "address:{addr}" }})')
    time.sleep(.15)

  def box(addr):
    c = n.client(addr)
    return (*c['at'], *c['size'])

  def boxes():
    return {name: box(win[name]) for name in names}

  def changed(before, after):
    return {k: tuple(a - b for a, b in zip(after[k], before[k])) for k in before}

  def drag_line(start, dx, dy):
    before = boxes()
    n.drag(start, (start[0] + dx, start[1] + dy), steps=12)
    time.sleep(.4)
    return changed(before, boxes())

  def near(d, want, slack=2):
    return all(abs(a - b) <= slack for a, b in zip(d, want))

  # 1. Two halves: tl on the left, tr on the right; bl, br out of the way.
  place(win['tl'], x0, y0, xm - half, y3)
  place(win['tr'], xm + half, y0, x3, y3)
  place(win['bl'], 100, 100, 300, 300)
  place(win['br'], 120, 120, 320, 320)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{win["tr"]}" }})')
  for name in ('tl', 'tr'):
    n.ctl('dispatch', f'hl.dsp.window.alter_zorder({{ mode = "top", window = "address:{win[name]}" }})')
  time.sleep(.3)
  tl = box(win['tl'])
  edge = (tl[0] + tl[2] + 4, ym)
  # The cursor on the shared edge, with the pointer drawn.
  n.pointer([f'move {edge[0] - 40} {edge[1]}', 'wait 60', f'move {edge[0]} {edge[1]}', 'wait 300'])
  subprocess.run(['grim', '-c', '-g', f'{edge[0] - 40},{edge[1] - 40} 80x80', str(artifacts / 'cursor-shared-edge.png')], env=n.env, check=False)
  # And during the drag, with the button held.
  held = subprocess.Popen([str(n.scratch / 'pointer'), *map(str, n.size())], stdin=subprocess.PIPE, text=True, env=n.env)
  held.stdin.write(f'move {edge[0]} {edge[1]}\nwait 100\ndown\nwait 100\nmove {edge[0] + 20} {edge[1]}\nwait 50\nmove {edge[0] + 30} {edge[1]}\n')
  held.stdin.flush()
  time.sleep(.6)
  subprocess.run(['grim', '-c', '-g', f'{edge[0] + 30 - 40},{edge[1] - 40} 80x80', str(artifacts / 'cursor-dragging.png')], env=n.env, check=False)
  held.stdin.write(f'move {edge[0]} {edge[1]}\nwait 50\nup\n')
  held.stdin.close()
  held.wait(5)
  time.sleep(.3)
  d = drag_line(edge, DX, DY)
  assert near(d['tl'], (0, 0, DX, 0)) and near(d['tr'], (DX, 0, -DX, 0)), ('halves', d)
  assert d['bl'] == (0, 0, 0, 0) and d['br'] == (0, 0, 0, 0), ('others moved', d)
  print('PASS: two halves resize together (sideways only)', flush=True)

  # 2. Four quarters.
  place(win['tl'], x0, y0, xm - half, ym - half)
  place(win['tr'], xm + half, y0, x3, ym - half)
  place(win['bl'], x0, ym + half, xm - half, y3)
  place(win['br'], xm + half, ym + half, x3, y3)
  tl = box(win['tl'])
  d = drag_line((tl[0] + tl[2] + 4, round((y0 + ym) / 2)), DX, 0)
  assert near(d['tl'], (0, 0, DX, 0)) and near(d['bl'], (0, 0, DX, 0)), ('left column', d)
  assert near(d['tr'], (DX, 0, -DX, 0)) and near(d['br'], (DX, 0, -DX, 0)), ('right column', d)
  print('PASS: the vertical line between four quarters moves all four', flush=True)

  tl = box(win['tl'])
  d = drag_line((tl[0] + tl[2] // 2, tl[1] + tl[3] + 4), 0, DY)
  assert near(d['tl'], (0, 0, 0, DY)) and near(d['bl'], (0, DY, 0, -DY)), ('left pair', d)
  assert d['tr'] == (0, 0, 0, 0) and d['br'] == (0, 0, 0, 0), ('the right pair moved', d)
  print('PASS: a horizontal line moves only the two windows it divides', flush=True)

  # 3. Turned off: only the window grabbed.
  n.ctl('eval', 'hl.config({ plugin = { windows_like = { joint_resize = 0 } } })')
  time.sleep(.3)
  tl = box(win['tl'])
  d = drag_line((tl[0] + tl[2] + 4, round((y0 + ym) / 2)), -DX, 0)
  assert near(d['tl'], (0, 0, -DX, 0)), ('the grabbed window', d)
  assert d['tr'] == d['bl'] == d['br'] == (0, 0, 0, 0), ('joint_resize = 0 moved others', d)
  print('PASS: joint_resize = 0 resizes one window at a time', flush=True)
  print('ALL PASS', flush=True)
