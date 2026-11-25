"""Check workspace mode switching with real compositor events and key presses.

Usage: python -I tests/test_workspace_bindings.py native/drag-events/drag-events.so
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested  # noqa: E402

ROOT = HERE.parent
CLI = ROOT / 'bin/omarchy-windows-like'
PLUGIN = Path(sys.argv[1]).resolve()
EXTRA = f'''
o = {{
  bind = function(keys, desc, action, opts)
    if type(action) == "string" then action = hl.dsp.exec_cmd(action) end
    hl.bind(keys, action, opts or {{ description = desc }})
  end,
}}
o.bind("SUPER + ALT + SPACE", "Apps", hl.dsp.event("native-apps"))
assert(loadfile("{ROOT / 'hypr/windows-like.lua'}"))("{CLI}")
'''


def wait_for(condition):
  for _ in range(50):
    if condition():
      return
    time.sleep(.1)
  raise AssertionError('Workspace mode did not take effect')


with tempfile.TemporaryDirectory(prefix='owl-workspace-home-') as temp:
  home = Path(temp)
  settings = home / '.config/omarchy-windows-like/settings.json'
  settings.parent.mkdir(parents=True)
  settings.write_text(json.dumps({
      'workspaces': {'scope': 'selected', 'selected': [1]},
      'general': {'floatingDefault': False},
  }))
  shell = home / '.config/omarchy/shell.json'
  shell.parent.mkdir(parents=True)
  omarchy = Path(os.environ.get('OMARCHY_PATH', '/usr/share/omarchy'))
  shutil.copyfile(omarchy / 'config/omarchy/shell.json', shell)
  plugins = shell.parent / 'plugins'
  plugins.mkdir()
  (plugins / 'io.github.neilgraham.windows-like').symlink_to(ROOT)
  theme = home / '.local/state/omarchy/current'
  theme.parent.mkdir(parents=True)
  theme.symlink_to(Path.home() / '.local/state/omarchy/current')
  with Nested(Path('/tmp/owl-workspace-bindings'), extra_config=EXTRA,
              extra_env={'HOME': temp, 'XDG_CONFIG_HOME': str(home / '.config'),
                         'XDG_STATE_HOME': str(home / '.local/state'),
                         'OMARCHY_WINDOWS_LIKE_NATIVE': str(PLUGIN)}) as nested:
    assert not nested.ctl('configerrors').strip(), nested.ctl('configerrors')
    if not json.loads(nested.ctl('monitors', '-j')):
      nested.ctl('output', 'create', 'headless', 'workspace-test')
    wait_for(lambda: json.loads(nested.ctl('monitors', '-j')))
    nested.open_window(extra=('-c', '/dev/null'))
    subprocess.run([CLI, 'apply'], env=nested.env, check=True)
    with (nested.artifacts / 'omarchy-shell.log').open('w') as log:
      compositor_shell = subprocess.Popen(
          ['quickshell', '-n', '-p', str(omarchy / 'shell')],
          env=dict(nested.env, OMARCHY_PATH=str(omarchy)), stdout=log, stderr=log)
    nested._clients.append(compositor_shell)

    def showed_mode(position, description):
      bars = json.loads(shell.read_text())
      bindings = json.loads(nested.ctl('binds', '-j'))
      reserved = json.loads(nested.ctl('monitors', '-j'))[0]['reserved']
      edge = 1 if position == 'top' else 3
      return (bars['bar']['position'] == position and reserved[edge] > 0
              and any(bind['description'] == description for bind in bindings))

    wait_for(lambda: showed_mode("bottom", "All apps"))
    nested.ctl('dispatch', 'hl.dsp.focus({ workspace = "2" })')
    wait_for(lambda: showed_mode("top", "Apps"))
    nested.shortcut('Super_L', 'Shift_L', 'F12')
    wait_for(lambda: showed_mode("bottom", "All apps"))
    nested.shortcut('Super_L', 'Shift_L', 'F12')
    wait_for(lambda: showed_mode("top", "Apps"))
    assert not nested.ctl('configerrors').strip(), nested.ctl('configerrors')
    print('PASS: workspace selection, native bindings and mode shortcut')
