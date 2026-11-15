"""Tabs: Ctrl + T / W / 1-9 / Tab in foot, the tab bar's buttons and scrolling,
terminal tab names, and keys passing through to other apps.

Usage: python -I tests/test_tabs.py native/drag-events/drag-events.so [artifacts-dir]
"""
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-tabs')
artifacts.mkdir(parents=True, exist_ok=True)

EXTRA = f'''
-- Animations on, as on a real desktop, so the test can see that tabs skip them.
hl.config({{ animations = {{ enabled = true }} }})
hl.plugin.load("{TITLEBARS}")
-- Omarchy's helper, which the module uses for one binding.
o = o or {{ bind = function(keys, desc, action) hl.bind(keys, action, {{ description = desc }}) end }}
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


def ctrl(n, key):
  n.shortcut('Control_L', key)


def ctrl_k(n, keysym, shift=False):
  n.shortcut('Control_L', *(['Shift_L'] if shift else []), keysym)


def quiet_while(n, done, settle=.5, timeout=6):
  """Samples what animates until done() holds and `settle` seconds more;
  returns the samples where anything moved or faded."""
  busy, deadline, finished = [], time.time() + timeout, None
  while time.time() < deadline:
    a = json.loads(n.ctl('windowslike-anim'))
    if a['animating'] or a['fadeouts']:
      busy.append(a)
    if finished is None and done():
      finished = time.time()
    if finished is not None and time.time() - finished > settle:
      return busy
    time.sleep(.01)
  raise AssertionError('timed out')


def center(box):
  x, y, w, h = box
  return x + w // 2, y + h // 2


with Nested(artifacts, extra_config=EXTRA, extra_env={'OMARCHY_WINDOWS_LIKE_NATIVE': str(plugin)}) as n:
  def tabs():
    return json.loads(n.ctl('windowslike-tabs'))

  def foot_windows():
    return [c for c in n.clients() if c['class'] == 'foot']

  def click(x, y, button='left'):
    down, up = ('down', 'up') if button == 'left' else ('mdown', 'mup')
    n.pointer([f'move {x} {y}', 'wait 150', down, 'wait 60', up, 'wait 300'])

  wait_for(lambda: any(p['name'] == 'windows-like-drag-events' for p in json.loads(n.ctl('plugin', 'list', '-j'))), what='plugin')
  errors = n.ctl('configerrors').strip()
  assert not errors, errors

  project = n.scratch / 'proj-alpha'
  project.mkdir()
  w1 = n.open_window(title=None, app_id='foot', cwd=str(project), command=None)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{w1["address"]}" }})')
  time.sleep(.5)
  assert tabs() == [], tabs()
  print('PASS: a single window shows no tab bar', flush=True)

  # Ctrl + T: a second foot, in the same folder, as a new tab: without an
  # animation, and with the window's frame staying where it was.
  before = n.client(w1['address'])
  ctrl(n, 't')
  busy = quiet_while(n, lambda: len(foot_windows()) == 2 and tabs())
  bars = wait_for(lambda: tabs(), what='tab bar')
  bar = bars[0]
  assert len(bar['tabs']) == 2 and bar['current'] == 1, bar
  assert all(len(c['grouped']) == 2 for c in foot_windows()), foot_windows()
  labels = wait_for(lambda: [t['label'] for t in tabs()[0]['tabs']] == ['proj-alpha', 'proj-alpha'] and True, timeout=4,
                    what='folder labels')
  n.capture('tabs-two')
  print('PASS: Ctrl+T opens a new tab in the same folder', flush=True)
  assert not busy, busy
  print('PASS: opening a tab doesn\'t animate', flush=True)
  TAB = 28
  now = n.client(bar['window'])
  assert now['at'] == [before['at'][0], before['at'][1] + TAB], (before['at'], now['at'])
  assert now['size'] == [before['size'][0], before['size'][1] - TAB], (before['size'], now['size'])
  print('PASS: the window\'s frame stays put as the tab bar appears', flush=True)

  # Terminal names follow what runs.
  n.key('sleep 300\n')
  wait_for(lambda: tabs()[0]['tabs'][1]['label'] == 'sleep 300', timeout=4, what='program label')
  print('PASS: a running program names its tab', flush=True)

  # Switching.
  ctrl(n, '1')
  wait_for(lambda: tabs()[0]['current'] == 0, what='Ctrl+1')
  ctrl_k(n, 'Tab')
  wait_for(lambda: tabs()[0]['current'] == 1, what='Ctrl+Tab')
  ctrl_k(n, 'Tab', shift=True)
  wait_for(lambda: tabs()[0]['current'] == 0, what='Ctrl+Shift+Tab')
  ctrl(n, '9')
  wait_for(lambda: tabs()[0]['current'] == 1, what='Ctrl+9')
  print('PASS: Ctrl+1/9, Ctrl+Tab, Ctrl+Shift+Tab switch tabs', flush=True)

  bar = tabs()[0]
  click(*center(bar['tabs'][0]['box']))
  wait_for(lambda: tabs()[0]['current'] == 0, what='click on tab 1')
  print('PASS: clicking a tab switches to it', flush=True)

  # "+" opens a third tab.
  click(*center(tabs()[0]['plus']))
  wait_for(lambda: len(tabs()[0]['tabs']) == 3 and tabs()[0]['current'] == 2, what='third tab')
  n.capture('tabs-three')
  print('PASS: + opens a new tab', flush=True)

  # Too many tabs to fit: the bar scrolls sideways.
  n.ctl('eval', 'hl.config({ plugin = { windows_like = { tab_min_width = 400 } } })')
  time.sleep(.3)
  bar = tabs()[0]
  assert bar['maxScroll'] > 0, bar
  assert bar['scroll'] == bar['maxScroll'], bar  # the current (last) tab is in view
  bx, by = center(bar['area'])
  n.pointer([f'move {bx} {by}', 'wait 150', 'hscroll -600', 'wait 300'])
  wait_for(lambda: tabs()[0]['scroll'] == 0, what='scroll back to the start')
  n.pointer([f'move {bx} {by}', 'wait 150', 'hscroll 150', 'wait 300'])
  mid = wait_for(lambda: tabs()[0]['scroll'], what='a partial scroll')
  assert 0 < mid < bar['maxScroll'], (mid, bar)
  n.capture('tabs-scrolled')
  print('PASS: the tab bar scrolls sideways when tabs overflow', flush=True)
  n.ctl('eval', 'hl.config({ plugin = { windows_like = { tab_min_width = 140 } } })')
  time.sleep(.3)

  # The close button of an inactive tab shows on hover, and closes it.
  bar = tabs()[0]
  first = bar['tabs'][0]
  n.pointer([f'move {center(first["box"])[0]} {center(first["box"])[1]}', 'wait 200'])
  cx, cy = center(tabs()[0]['tabs'][0]['close'])
  click(cx, cy)
  wait_for(lambda: len(foot_windows()) == 2, what='close button')
  assert first['address'] not in [c['address'] for c in foot_windows()]
  print('PASS: a tab\'s close button closes it', flush=True)

  # Middle click closes a tab; the bar goes away with the second-last tab.
  bar = tabs()[0]
  x, y = center(bar['tabs'][0]['box'])
  n.pointer([f'move {x} {y}', 'wait 150', 'mdown', 'wait 60'])
  n.pointer(['mup'])  # release separately, so the sampling below sees the close
  busy = quiet_while(n, lambda: len(foot_windows()) == 1 and tabs() == [])
  print('PASS: middle click closes a tab, and one tab shows no bar', flush=True)
  assert not busy, busy
  print('PASS: closing a tab doesn\'t animate', flush=True)
  last = foot_windows()[0]
  assert last['at'] == before['at'] and last['size'] == before['size'], (before['at'], before['size'], last['at'], last['size'])
  print('PASS: the window\'s frame stays put as the tab bar goes', flush=True)

  # Ctrl + W closes the last tab (the window).
  ctrl(n, 'w')
  wait_for(lambda: len(foot_windows()) == 0, what='Ctrl+W')
  print('PASS: Ctrl+W closes the tab', flush=True)

  # Other apps get the keys: a terminal of another class reads Ctrl+T raw.
  out = n.scratch / 'key.bin'
  # (Also the control for the animation checks: an ordinary window opening,
  # which isn't a tab, does animate, so they can see an animation.)
  import threading
  seen = []
  watcher = threading.Thread(target=lambda: seen.extend(quiet_while(n, lambda: len(n.clients()) == 1, settle=.3)))
  watcher.start()
  other = n.open_window(title='other', app_id='other-app', command=('sh', '-c', f'stty raw -echo; head -c1 > {out}; sleep 5'))
  watcher.join()
  assert seen, 'an ordinary window opening should animate'
  print('PASS: control: an ordinary window opening animates', flush=True)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{other["address"]}" }})')
  time.sleep(.5)
  ctrl(n, 't')
  wait_for(lambda: out.exists() and out.read_bytes() == b'\x14', what='Ctrl+T to reach the other app')
  assert not foot_windows() and len(n.clients()) == 1, n.clients()
  print('PASS: Ctrl+T reaches other apps untouched', flush=True)

  # A window with tabs snaps with its title bar and tab bar inside the zone.
  n.ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "omarchy-floating-workspace" } } })')
  w = n.open_window(title=None, app_id='foot', cwd=str(project), command=None)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{w["address"]}" }})')
  time.sleep(.3)
  ctrl(n, 't')
  wait_for(lambda: tabs(), what='tabs for snapping')
  for c in foot_windows():
    n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{c["address"]}" }})')
  n.start_shell(HERE.parent / 'WindowsLike.qml')
  n.ipc('assist', 'off')
  state = n.ipc('state')
  assert state['tabBarHeight'] == 28, state
  current = n.client(tabs()[0]['window'])
  start = (current['at'][0] + 200, current['at'][1] - 28 - 15)  # on the title bar, above the tabs
  n.drag(start, (0, n.height // 2))
  # The zone, computed as the shell plugin does: from the unrounded logical
  # size (the nested screen's scale can be fractional), rounding only edges.
  monitor = json.loads(n.ctl('monitors', '-j'))[0]
  width, height = monitor['width'] / monitor['scale'], monitor['height'] / monitor['scale']
  border, bar, tab, gaps_out, gaps_in = 2, 30, 28, 10, 5
  right = round(gaps_out + (width - 2 * gaps_out) / 2 - gaps_in)
  bottom = round(gaps_out + height - 2 * gaps_out)
  want_at = [gaps_out + border, gaps_out + border + bar + tab]
  want_size = [right - gaps_out - 2 * border, bottom - gaps_out - 2 * border - bar - tab]
  # The shell asks for exactly want_size; Hyprland gives a grouped window a
  # pixel more height than asked for, so allow that.
  def snapped():
    c = n.client(current['address'])
    ok = c['at'] == want_at and c['size'][0] == want_size[0] and 0 <= c['size'][1] - want_size[1] <= 1
    return c if ok else None
  wait_for(snapped, timeout=4, what=f'snap to {want_at} {want_size}, got {n.client(current["address"])["at"]} {n.client(current["address"])["size"]}')
  n.capture('tabs-snapped')
  print('PASS: a window with tabs snaps to the left half, tab bar included', flush=True)
  print('ALL PASS', flush=True)
