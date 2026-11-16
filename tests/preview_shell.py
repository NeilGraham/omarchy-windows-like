"""Runs Omarchy's real shell, with the Windows-like taskbar applied, inside a
nested Hyprland and a scratch home, and takes screenshots. Nothing touches the
real session: the shell config is a copy, and the nested session's runtime dir
keeps its shell's IPC apart from the real one.

Usage: python -I tests/preview_shell.py native/drag-events/drag-events.so [artifacts-dir] [windows11|classic] [bottom|top]
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
from nested import Nested, TITLEBARS  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-preview')
style = sys.argv[3] if len(sys.argv) > 3 else 'windows11'
position = sys.argv[4] if len(sys.argv) > 4 else 'bottom'
artifacts.mkdir(parents=True, exist_ok=True)
real_home = Path(os.environ['HOME'])

# ---------- A scratch home with the taskbar applied ----------
home = artifacts / 'home'
shutil.rmtree(home, ignore_errors=True)
(home / '.config/omarchy/plugins').mkdir(parents=True)
(home / '.local/state/omarchy').mkdir(parents=True)
shutil.copy(real_home / '.config/omarchy/shell.json', home / '.config/omarchy/shell.json')
(home / '.config/omarchy/plugins/io.github.neilgraham.windows-like').symlink_to(REPO)
(home / '.local/state/omarchy/current').symlink_to(real_home / '.local/state/omarchy/current')
for keep in ('.config/fontconfig', '.local/share/fonts', '.local/share/applications', '.local/share/icons'):
  if (real_home / keep).exists():
    (home / keep).parent.mkdir(parents=True, exist_ok=True)
    (home / keep).symlink_to(real_home / keep)
settings = home / '.config/omarchy-windows-like/settings.json'
settings.parent.mkdir(parents=True)
settings.write_text(json.dumps({
  'taskbar': {'style': style, 'position': position, 'pinned': ['org.gnome.Nautilus', 'chromium', 'foot']},
  'start': {'pinned': ['org.gnome.Nautilus', 'chromium', 'foot', 'omacalc', 'omawrite']},
}))
stubs = artifacts / 'stubs'
shutil.rmtree(stubs, ignore_errors=True)
stubs.mkdir()
for name in ('omarchy', 'hyprctl'):
  (stubs / name).write_text('#!/bin/sh\nexit 0\n')
  (stubs / name).chmod(0o755)
env = dict(os.environ, HOME=str(home), PATH=f'{stubs}:{os.environ["PATH"]}')
subprocess.run([str(REPO / 'bin/omarchy-windows-like'), 'apply'], env=env, check=True)

# ---------- The nested session ----------
extra = f'''
hl.plugin.load("{TITLEBARS}")
o = o or {{ bind = function(k, d, a, opts) hl.bind(k, a, opts or {{ description = d }}) end,
            rebind = function(k, d, a, opts) hl.bind(k, a, opts or {{ description = d }}) end }}
dofile("{REPO / 'hypr/windows-like.lua'}")
'''
with Nested(artifacts, extra_config=extra, extra_env={'OMARCHY_WINDOWS_LIKE_NATIVE': str(plugin),
                                                      'OMARCHY_WINDOWS_LIKE_SETTINGS': str(home / '.config/omarchy-windows-like/settings.lua')}) as n:
  shell_env = dict(n.env, HOME=str(home), OMARCHY_PATH='/usr/share/omarchy')
  shell_log = (artifacts / 'omarchy-shell.log').open('w')
  shell = subprocess.Popen(['quickshell', '-n', '-p', '/usr/share/omarchy/shell'], env=shell_env, stdout=shell_log, stderr=shell_log)
  n._clients.append(shell)
  for _ in range(100):
    if json.loads(n.ctl('monitors', '-j'))[0]['reserved'] != [0, 0, 0, 0]:
      break
    time.sleep(.2)
  print('reserved', json.loads(n.ctl('monitors', '-j'))[0]['reserved'], flush=True)
  time.sleep(2)
  w1 = n.open_window('Terminal one', app_id='foot', command=None)
  w2 = n.open_window('Terminal two', app_id='foot', command=None)
  time.sleep(1)
  n.capture(f'{style}-{position}-taskbar')

  n.ctl('dispatch', 'hl.dsp.event("windows-like-start")')
  time.sleep(1.2)
  n.capture(f'{style}-{position}-start')
  n.ctl('dispatch', 'hl.dsp.event("windows-like-start")')
  time.sleep(.6)

  n.ctl('dispatch', 'hl.dsp.event("windows-like-start-apps")')
  time.sleep(1.2)
  n.capture(f'{style}-{position}-all-apps')
  n.ctl('dispatch', 'hl.dsp.event("windows-like-start-apps")')
  time.sleep(.6)

  # Right-click an app button (the middle of the bar, just right of Start)
  # for its menu; every row must show.
  width, height = n.size()
  bar_y = height - 20 if position == 'bottom' else 20
  app_x = round(width / 2) if style == 'windows11' else 140
  n.pointer([f'move {app_x} {bar_y}', 'wait 200', 'rdown', 'wait 60', 'rup', 'wait 900'])
  n.capture(f'{style}-{position}-app-menu')
  n.pointer(['wait 100', f'move {round(width / 2)} {round(height / 2)}', 'down', 'wait 60', 'up', 'wait 500'])
  # And a running app's, which has the most rows (new window, pin, close).
  n.pointer([f'move {app_x + 45} {bar_y}', 'wait 200', 'rdown', 'wait 60', 'rup', 'wait 900'])
  n.capture(f'{style}-{position}-running-app-menu')
  n.pointer(['wait 100', f'move {round(width / 2)} {round(height / 2)}', 'down', 'wait 60', 'up', 'wait 500'])

  # The clock is the last widget on the bar: click it for the calendar.
  width, height = n.size()
  bar_y = height - 20 if position == 'bottom' else 20
  n.pointer([f'move {width - 60} {bar_y}', 'wait 200', 'down', 'wait 60', 'up', 'wait 1200'])
  n.capture(f'{style}-{position}-calendar')
  shell.terminate()
  shell_log.close()
print('screenshots in', artifacts, flush=True)
