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


# The defaults, not whatever the person running the tests has chosen.
no_settings = artifacts / 'no-settings.lua'
no_settings.write_text('return {}\n')

with Nested(artifacts, extra_config=EXTRA, extra_env={'OMARCHY_WINDOWS_LIKE_NATIVE': str(plugin),
                                                      'OMARCHY_WINDOWS_LIKE_SETTINGS': str(no_settings)}) as n:
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
  # Foot shows its tab from the start, in the title bar: the logo where the
  # app's name was, the tab, "+", and the title bar's buttons left free.
  bar = wait_for(lambda: tabs(), what='a tab in the title bar')[0]
  assert bar['titleBar'], bar
  assert len(bar['tabs']) == 1 and bar['current'] == 0, bar
  BAR, BUTTONS = 30, 94
  bx, by, bw, bh = bar['bar']
  assert bh == BAR, bar
  first = n.client(w1['address'])
  assert by + bh == first['at'][1] and bx == first['at'][0], (bar, first)
  assert bar['logo'][0] - bx < 10 and bar['logo'][0] + bar['logo'][2] <= bar['area'][0], bar
  assert bar['logoLoaded'], 'foot\'s icon should be found'
  assert bar['plus'][0] == bar['area'][0] + bar['area'][2], bar  # "+" right after the tab
  assert bar['strip'][0] + bar['strip'][2] <= bx + bw - BUTTONS, bar
  n.capture('tabs-one')
  print('PASS: a single foot shows its logo, its tab and + in the title bar', flush=True)

  # Resting on the logo names the app; moving off puts the name away.
  lx, ly = center(bar['logo'])
  n.pointer([f'move {lx} {ly}', 'wait 900'])
  wait_for(lambda: tabs()[0]['tip'] == 'Foot', timeout=3, what='the app\'s name on the logo')
  n.capture('tabs-tooltip')
  n.pointer([f'move {lx} {ly + 200}', 'wait 200'])
  wait_for(lambda: tabs()[0]['tip'] == '', timeout=3, what='the name to go')
  print('PASS: resting on the logo shows the app\'s name', flush=True)

  # Ctrl + T: a second foot, in the same folder, as a new tab: without an
  # animation, and with the window's frame staying where it was.
  before = n.client(w1['address'])
  ctrl(n, 't')
  busy = quiet_while(n, lambda: len(foot_windows()) == 2 and len(tabs()[0]['tabs']) == 2)
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
  now = n.client(bar['window'])
  assert now['at'] == before['at'] and now['size'] == before['size'], (before, now)
  assert bar['bar'][3] == BAR, bar
  print('PASS: the window keeps its size: tabs take no room of their own', flush=True)

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

  # "+" opens a third tab. Two quick clicks there (or on a tab's close
  # button) are not a double click on the title bar: the window stays as it
  # is, unmaximized and unmoved.
  framed = n.client(tabs()[0]['window'])
  px, py = center(tabs()[0]['plus'])
  n.pointer([f'move {px} {py}', 'wait 150', 'down', 'wait 40', 'up', 'wait 120', 'down', 'wait 40', 'up', 'wait 400'])
  wait_for(lambda: len(tabs()[0]['tabs']) == 4 and tabs()[0]['current'] == 3, what='two new tabs')
  time.sleep(.5)
  c = n.client(tabs()[0]['window'])
  assert not c.get('fullscreen') and c['at'] == framed['at'] and c['size'] == framed['size'], (framed, c)
  n.capture('tabs-four')
  print('PASS: + opens a new tab, and a quick second click isn\'t a double click', flush=True)
  ctrl(n, 'w')
  wait_for(lambda: len(tabs()[0]['tabs']) == 3, what='back to three tabs')

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

  # Middle click closes a tab; the last tab stays in the title bar.
  bar = tabs()[0]
  x, y = center(bar['tabs'][0]['box'])
  n.pointer([f'move {x} {y}', 'wait 150', 'mdown', 'wait 60'])
  n.pointer(['mup'])  # release separately, so the sampling below sees the close
  busy = quiet_while(n, lambda: len(foot_windows()) == 1 and tabs() and len(tabs()[0]['tabs']) == 1)
  print('PASS: middle click closes a tab, and the last tab stays', flush=True)
  assert not busy, busy
  print('PASS: closing a tab doesn\'t animate', flush=True)
  last = foot_windows()[0]
  assert last['at'] == before['at'] and last['size'] == before['size'], (before['at'], before['size'], last['at'], last['size'])
  print('PASS: the window\'s frame stays put as tabs close', flush=True)

  # A window dragged by its title bar and dropped on a tabbed window (on its
  # tab bar, or anywhere on it) stays a window of its own, as does one dragged
  # by its tab and dropped on the window rather than its tabs: joining tabs
  # takes dropping a tab on them (see test_tab_drag.py).
  ctrl(n, 't')
  bar = wait_for(lambda: len(tabs()[0]['tabs']) == 2 and tabs(), what='tabs again')[0]
  stray = n.open_window(title='stray', app_id='stray-app')
  n.ctl('dispatch', f'hl.dsp.window.move({{ x = 20, y = 300, window = "address:{stray["address"]}" }})')
  time.sleep(.3)
  stray = n.client(stray['address'])
  on_tabs, on_window = center(bar['tabs'][0]['box']), center(bar['area'])[0:1] + (bar['bar'][1] + 120,)
  # (The stray is a foot, so it shows its tab: the logo is its title bar.)
  for by, target in (('logo', on_tabs), ('logo', on_window), ('tab', on_window)):
    s0 = n.client(stray['address'])
    grab = (s0['at'][0] + 19, s0['at'][1] - 15) if by == 'logo' else (s0['at'][0] + 100, s0['at'][1] - 15)
    n.drag(grab, target)
    time.sleep(.3)
    assert not n.client(stray['address'])['grouped'], ('dropped window joined the tabs', by, target)
    assert n.client(stray['address'])['at'] != s0['at'], ('the window didn\'t move', by)
  assert len(tabs()[0]['tabs']) == 2, tabs()
  n.ctl('dispatch', f'hl.dsp.window.close({{ window = "address:{stray["address"]}" }})')
  wait_for(lambda: not any(c['address'] == stray['address'] for c in n.clients()), what='stray to close')
  print('PASS: dropping a window on a tabbed window doesn\'t make it a tab', flush=True)
  ctrl(n, 'w')
  wait_for(lambda: len(tabs()[0]['tabs']) == 1, what='back to one tab')

  # Ctrl + W closes the last tab (the window).
  ctrl(n, 'w')
  wait_for(lambda: len(foot_windows()) == 0, what='Ctrl+W')
  print('PASS: Ctrl+W closes the tab', flush=True)

  # A foot opened under an app id of its own (Omarchy's agent terminal is
  # one) still gets the tab shortcuts.
  agent = n.open_window(title=None, app_id='org.omarchy.agent', cwd=str(project), command=None)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{agent["address"]}" }})')
  time.sleep(.3)
  ctrl(n, 't')
  bar = wait_for(lambda: tabs() and len(tabs()[0]['tabs']) == 2 and tabs(), what='a tab from the agent terminal')[0]
  assert len(bar['tabs']) == 2, bar
  joined = [c for c in n.clients() if c['address'] != agent['address']][0]
  assert joined['class'] == 'foot', joined  # a plain terminal, not another agent window
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{joined["address"]}" }})')
  ctrl(n, '1')
  wait_for(lambda: tabs() and tabs()[0]['current'] == 0, what='Ctrl+1 from the new tab')
  print('PASS: a foot with its own app id gets the tab shortcuts', flush=True)
  for c in n.clients():
    n.ctl('dispatch', f'hl.dsp.window.close({{ window = "address:{c["address"]}" }})')
  wait_for(lambda: not n.clients(), what='windows to close')

  # Other apps get the keys: a terminal of another class reads Ctrl+T raw.
  # (It is foot too, the only terminal at hand, so foot-by-program is off for
  # this check: the class decides, as it does for every other app.)
  n.ctl('eval', 'hl.config({ plugin = { windows_like = { tab_programs = "^$" } } })')
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

  # A window with tabs snaps with its title bar (tabs and all) inside the zone.
  n.ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "omarchy-floating-workspace" } } })')
  w = n.open_window(title=None, app_id='foot', cwd=str(project), command=None)
  n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{w["address"]}" }})')
  time.sleep(.3)
  ctrl(n, 't')
  wait_for(lambda: tabs() and len(tabs()[0]['tabs']) == 2, what='tabs for snapping')
  for c in foot_windows():
    n.ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+omarchy-floating-workspace", window = "address:{c["address"]}" }})')
  n.start_shell(HERE.parent / 'WindowsLike.qml')
  n.ipc('assist', 'off')
  state = n.ipc('state')
  assert state['tabBarHeight'] == 28, state
  current = n.client(tabs()[0]['window'])
  start = center(tabs()[0]['logo'])  # the logo is title bar: dragging it moves the window, tabs and all
  n.drag(start, (0, n.height // 2))
  # The zone, computed as the shell plugin does: from the unrounded logical
  # size (the nested screen's scale can be fractional), rounding only edges.
  monitor = json.loads(n.ctl('monitors', '-j'))[0]
  width, height = monitor['width'] / monitor['scale'], monitor['height'] / monitor['scale']
  # Snapped windows meet each other and the screen's edges (snapping.gaps off).
  border, bar, tab, gaps_out, gaps_in = 2, 30, 28, 0, 0
  right = round(gaps_out + (width - 2 * gaps_out) / 2 - gaps_in)
  bottom = round(gaps_out + height - 2 * gaps_out)
  want_at = [gaps_out + border, gaps_out + border + bar]
  want_size = [right - gaps_out - 2 * border, bottom - gaps_out - 2 * border - bar]
  # The shell asks for exactly want_size; Hyprland gives a grouped window a
  # pixel more height than asked for, so allow that.
  def snapped():
    c = n.client(current['address'])
    ok = c['at'] == want_at and c['size'][0] == want_size[0] and 0 <= c['size'][1] - want_size[1] <= 1
    return c if ok else None
  wait_for(snapped, timeout=4, what=f'snap to {want_at} {want_size}, got {n.client(current["address"])["at"]} {n.client(current["address"])["size"]}')
  n.capture('tabs-snapped')
  print('PASS: dragging the logo moves the tabbed window, which snaps to the left half', flush=True)

  # A tab dragged out of the strip tears off into a window of its own, which
  # snaps like any dragged window: into the room right of the tabbed one.
  group = tabs()[0]
  torn = next(t['address'] for t in group['tabs'] if t['address'] != current['address'])
  start = center(next(t['box'] for t in group['tabs'] if t['address'] == torn))
  n.drag(start, (start[0], start[1] + 150), (round(width) - 1, n.height // 2))
  edge = round(width) - gaps_out - border
  def snapped_right():
    c = n.client(torn)
    ok = (not c['grouped'] and c['at'][1] == want_at[1] and abs(c['at'][0] + c['size'][0] - edge) <= 1
          and c['at'][0] > width / 2 - 20 and abs(c['size'][1] - want_size[1]) <= 1)
    return c if ok else None
  wait_for(snapped_right, timeout=4, what=f'the torn-off tab to snap right, got {n.client(torn)["at"]} {n.client(torn)["size"]}')
  assert snapped(), n.client(current['address'])
  n.capture('tabs-torn-off-snapped')
  print('PASS: a tab torn off by dragging snaps to the right half', flush=True)
  print('ALL PASS', flush=True)
