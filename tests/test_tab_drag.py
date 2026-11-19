"""Dragging tabs: a click still just selects, dragging along the strip
reorders, dragging out tears a tab off into a window of its own (which goes on
being dragged, and is reported like any window drag), and a window carried by
its tab onto another window's tabs joins them where it is dropped. A double
click on a tab does what one on the title bar does.

Usage: python -I tests/test_tab_drag.py native/drag-events/drag-events.so [artifacts-dir]
"""
import json
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-tab-drag')
artifacts.mkdir(parents=True, exist_ok=True)

EXTRA = f'''
hl.config({{ animations = {{ enabled = true }} }})
hl.plugin.load("{TITLEBARS}")
o = o or {{
  bind = function(keys, desc, action, opts) hl.bind(keys, action, opts or {{ description = desc }}) end,
  rebind = function(keys, desc, action, opts) hl.bind(keys, action, opts or {{ description = desc }}) end,
}}
dofile("{HERE.parent / 'hypr' / 'windows-like.lua'}")
'''


def wait_for(fn, timeout=5, what='condition'):
  deadline = time.time() + timeout
  while time.time() < deadline:
    value = fn()
    if value:
      return value
    time.sleep(.1)
  raise AssertionError(f'timed out waiting for {what}')


def center(box):
  x, y, w, h = box
  return x + w // 2, y + h // 2


def parse(event):
  kind, mode, address, cx, cy, x, y, w, h = event.split(':', 1)[1].split('|')
  return {'kind': kind, 'mode': mode, 'address': address, 'cursor': (int(cx), int(cy))}


no_settings = artifacts / 'no-settings.lua'
no_settings.write_text('return {}\n')

with Nested(artifacts, extra_config=EXTRA, extra_env={'OMARCHY_WINDOWS_LIKE_NATIVE': str(plugin),
                                                      'OMARCHY_WINDOWS_LIKE_SETTINGS': str(no_settings)}) as n:
  def bars():
    return json.loads(n.ctl('windowslike-tabs'))

  def bar_of(address):
    """The tab bar showing the window (or the group it is a tab of)."""
    for b in bars():
      if b['window'] == address or any(t['address'] == address for t in b['tabs']):
        return b
    return None

  def order(address):
    return [t['address'] for t in bar_of(address)['tabs']]

  def press_path(start, *points, hold=0, steps=20):
    sx, sy = start
    commands = [f'move {sx} {sy}', 'wait 100', 'down', 'wait 120']
    for ex, ey in points:
      for i in range(1, steps + 1):
        commands += [f'move {round(sx + (ex - sx) * i / steps)} {round(sy + (ey - sy) * i / steps)}', 'wait 20']
      sx, sy = ex, ey
    return commands + [f'wait {hold}', 'up', 'wait 200']

  def while_held(start, *points, check, steps=20):
    """Drags, and calls check() while the button is still held at the end."""
    moving = 0.22 + len(points) * steps * 0.025
    t = threading.Thread(target=n.pointer, args=(press_path(start, *points, hold=1500, steps=steps),))
    t.start()
    time.sleep(moving + .5)
    try:
      return check()
    finally:
      t.join()
      time.sleep(.3)

  wait_for(lambda: any(p['name'] == 'windows-like-drag-events' for p in json.loads(n.ctl('plugin', 'list', '-j'))), what='plugin')
  errors = n.ctl('configerrors').strip()
  assert not errors, errors

  project = n.scratch / 'proj'
  project.mkdir()
  first = n.open_window(title=None, app_id='foot', cwd=str(project), command=None)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{first["address"]}" }})')
  time.sleep(.5)
  for count in (2, 3):
    n.shortcut('Control_L', 't')
    wait_for(lambda: bars() and len(bars()[0]['tabs']) == count, what=f'{count} tabs')
  time.sleep(.5)
  A, B, C = order(first['address'])
  frame = n.client(bar_of(A)['window'])

  # A press that moves less than the threshold is a click: it selects the tab,
  # and neither reorders nor moves anything.
  bar = bar_of(A)
  x, y = center(bar['tabs'][0]['box'])
  n.pointer([f'move {x} {y}', 'wait 100', 'down', 'wait 60', f'move {x + 3} {y + 2}', 'wait 60', 'up', 'wait 300'])
  wait_for(lambda: bar_of(A)['current'] == 0, what='the click to select tab 1')
  assert order(A) == [A, B, C], order(A)
  now = n.client(bar_of(A)['window'])
  assert now['at'] == frame['at'], (frame['at'], now['at'])
  print('PASS: a click on a tab (with a little jitter) selects it', flush=True)

  # Along the strip: the first tab follows the pointer to the last place; the
  # others make room as it passes them. The window stays where it is.
  bar = bar_of(A)
  start = center(bar['tabs'][0]['box'])
  end = center(bar['tabs'][2]['box'])
  def mid_reorder():
    b = bar_of(A)
    n.capture('reordering')
    return b['dragging'], [t['address'] for t in b['tabs']]
  dragging, mid = while_held(start, end, check=mid_reorder)
  assert mid == [B, C, A] and dragging == 2, (dragging, mid)
  wait_for(lambda: order(A) == [B, C, A], what='the new order')
  b = bar_of(A)
  assert b['current'] == 2 and b['window'] == A and b['dragging'] == -1, b
  now = n.client(A)
  assert now['at'] == frame['at'] and now['size'] == frame['size'], (frame, now)
  assert all(len(c['grouped']) == 3 for c in n.clients()), n.clients()
  n.capture('reordered')
  print('PASS: dragging a tab along the strip reorders the tabs', flush=True)

  bar = bar_of(A)
  n.drag(center(bar['tabs'][2]['box']), center(bar['tabs'][0]['box']))
  wait_for(lambda: order(A) == [A, B, C], what='the order back')
  print('PASS: and back again', flush=True)

  # Out of the strip: the middle tab tears off into a window of its own,
  # under the pointer (holding it by its tab as the tab was held), and is
  # dragged on as a window: the drag is reported like a title bar drag.
  n.events.clear()
  bar = bar_of(A)
  start = center(bar['tabs'][1]['box'])
  drop = (start[0] + 80, start[1] + 260)
  n.drag(start, drop)
  wait_for(lambda: not n.client(B)['grouped'], what='the tab to tear off')
  torn = n.client(B)
  assert torn['size'] == frame['size'], (torn, frame)
  assert order(A) == [A, C], order(A)
  assert all(len(n.client(a)['grouped']) == 2 for a in (A, C)), n.clients()
  group = n.client(bar_of(A)['window'])
  assert group['at'] == frame['at'], (frame, group)
  tb = bar_of(B)
  assert tb and tb['window'] == B and len(tb['tabs']) == 1, tb
  # (Its one tab is wider than the three were: held as far from its left.)
  held = (start[0] - bar['tabs'][1]['box'][0], start[1] - bar['bar'][1])
  now_held = (drop[0] - tb['tabs'][0]['box'][0], drop[1] - tb['bar'][1])
  assert abs(now_held[0] - held[0]) <= 3 and abs(now_held[1] - held[1]) <= 3, (held, now_held)
  ev = [parse(e) for e in n.custom()]
  kinds = [e['kind'] for e in ev]
  assert kinds and kinds[0] == 'start' and kinds[-1] == 'end' and 'move' in kinds, kinds
  assert all(e['address'] == B and e['mode'] == 'move' for e in ev), ev
  assert abs(ev[-1]['cursor'][0] - drop[0]) <= 2 and abs(ev[-1]['cursor'][1] - drop[1]) <= 2, ev[-1]
  n.capture('torn-off')
  print('PASS: dragging a tab out of the strip tears it off into a window, dragged on and reported', flush=True)

  # A window with one tab is moved by its tab, like by its title bar.
  before = n.client(B)
  tb = bar_of(B)
  start = center(tb['tabs'][0]['box'])
  n.drag(start, (start[0] + 60, start[1] + 40))
  wait_for(lambda: n.client(B)['at'] == [before['at'][0] + 60, before['at'][1] + 40], what=f'the window to move, at {n.client(B)["at"]}')
  assert not n.client(B)['grouped']
  print('PASS: dragging the tab of a window with one tab moves the window', flush=True)

  # Carried by its tab onto the other window's tabs, between its two: shown
  # there as a tab while it is over them, and one of them where it is dropped.
  tb, gb = bar_of(B), bar_of(A)
  start = center(tb['tabs'][0]['box'])
  between = (gb['tabs'][1]['box'][0], center(gb['tabs'][1]['box'])[1])
  def mid_carry():
    n.capture('carried-over-tabs')
    return bar_of(A)['drop']
  slot = while_held(start, between, check=mid_carry)
  assert slot == 1, slot
  wait_for(lambda: len(n.client(B)['grouped']) == 3, what='the window to join the tabs')
  assert order(A) == [A, B, C], order(A)
  b = bar_of(A)
  assert b['current'] == 1 and b['window'] == B and b['drop'] == -1, b
  now = n.client(B)
  assert now['at'] == frame['at'] and now['size'] == frame['size'], (frame, now)
  n.capture('re-attached')
  print('PASS: a window dropped by its tab on another window\'s tabs joins them where it is dropped', flush=True)

  # Torn off and dropped straight back, in one drag: at the end.
  bar = bar_of(A)
  start = center(bar['tabs'][0]['box'])
  away = (start[0], start[1] + 200)
  back = (bar['plus'][0] - 5, center(bar['plus'])[1])
  n.drag(start, away, back)
  wait_for(lambda: order(B) == [B, C, A], what=f'A torn off and back at the end, order {order(B)}')
  print('PASS: a tab torn off can be dropped back in the same drag', flush=True)

  # A double click on a tab runs the title bar's double click action, for
  # that window (Omarchy's maximizes it).
  marker = n.scratch / 'double-click'
  n.ctl('eval', f'hl.config({{ plugin = {{ hyprbars = {{ on_double_click = "echo %WINDOW% > {marker}" }} }} }})')
  bar = bar_of(A)
  x, y = center(bar['tabs'][1]['box'])
  n.pointer([f'move {x} {y}', 'wait 100', 'down', 'wait 40', 'up', 'wait 120', 'down', 'wait 40', 'up', 'wait 300'])
  wait_for(lambda: marker.exists() and marker.read_text().strip(), what='the double click action')
  assert marker.read_text().strip() == C, (marker.read_text(), C)
  assert order(A) == [B, C, A], order(A)
  print('PASS: a double click on a tab runs the title bar\'s double click action', flush=True)

  for c in n.clients():
    n.ctl('dispatch', f'hl.dsp.window.close({{ window = "address:{c["address"]}" }})')
  wait_for(lambda: not n.clients(), what='windows to close')
  print('ALL PASS', flush=True)
