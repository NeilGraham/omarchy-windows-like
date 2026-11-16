"""A disposable nested Hyprland for tests, driven by a virtual pointer.

Nothing here talks to the parent session except to open the nested
compositor's window on it: every hyprctl call carries the nested instance's
signature and runtime dir, and plugin commands refuse to run otherwise.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
WIDTH, HEIGHT = 1280, 800
TITLEBARS = Path('/usr/lib/omarchy-hyprland-titlebars/titlebars.so')

CONFIG = '''
hl.monitor({ output = "", mode = "1280x800@60", position = "0x0", scale = 1 })
hl.config({
  general = { gaps_in = 5, gaps_out = 10, border_size = 2, resize_on_border = true, extend_border_grab_area = 8 },
  animations = { enabled = false },
  input = { follow_mouse = 0 },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
})
hl.window_rule({ name = "test-float", match = { class = ".*" }, float = true, size = { 600, 400 }, center = true })
if hl.plugin and hl.plugin.hyprbars then
  hl.config({ plugin = { hyprbars = {
    enabled = true, bar_height = 30, bar_color = "rgb(24283b)", col = { text = "rgb(c0caf5)" },
    bar_part_of_window = true, bar_precedence_over_border = true,
  } } })
end
'''


class Nested:
  def __init__(self, artifacts: Path, extra_config: str = '', extra_env: dict | None = None):
    self.extra_config = extra_config
    self.extra_env = extra_env or {}
    self.artifacts = artifacts
    artifacts.mkdir(parents=True, exist_ok=True)
    self._tmp = tempfile.TemporaryDirectory(prefix='owl-')
    self.scratch = Path(self._tmp.name)
    self.events: list[str] = []
    self._clients: list[subprocess.Popen] = []

  # ----- lifecycle -----

  def __enter__(self):
    for kind, target in [('client-header', 'pointer-protocol.h'), ('private-code', 'pointer-protocol.c')]:
      subprocess.run(['wayland-scanner', kind, str(HERE / 'wlr-virtual-pointer-unstable-v1.xml'), str(self.scratch / target)], check=True)
    subprocess.run(['cc', str(HERE / 'pointer.c'), str(self.scratch / 'pointer-protocol.c'), '-I', str(self.scratch),
                    '-lwayland-client', '-o', str(self.scratch / 'pointer')], check=True)
    for kind, target in [('client-header', 'keyboard-protocol.h'), ('private-code', 'keyboard-protocol.c')]:
      subprocess.run(['wayland-scanner', kind, str(HERE / 'virtual-keyboard-unstable-v1.xml'), str(self.scratch / target)], check=True)
    subprocess.run(['cc', str(HERE / 'keyboard.c'), str(self.scratch / 'keyboard-protocol.c'), '-I', str(self.scratch),
                    '-lwayland-client', '-lxkbcommon', '-o', str(self.scratch / 'keyboard')], check=True)
    config = self.scratch / 'hyprland.lua'
    config.write_text(CONFIG + self.extra_config)

    parents = json.loads(subprocess.check_output(['hyprctl', 'instances', '-j'], text=True))
    if len(parents) != 1:
      raise RuntimeError('tests expect exactly one parent compositor')
    self.parent_signature = parents[0]['instance']
    parent_display = str(Path(os.environ['XDG_RUNTIME_DIR']) / parents[0]['wl_socket'])
    self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.scratch), AQ_BACKEND='wayland', WAYLAND_DISPLAY=parent_display,
                    HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_SD_VARS='1', **self.extra_env)
    self.env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
    self.log = (self.artifacts / 'compositor.log').open('w')
    self.compositor = subprocess.Popen(['Hyprland', '--config', str(config)], env=self.env, stdout=self.log, stderr=self.log)

    for _ in range(100):
      if self.compositor.poll() is not None:
        raise RuntimeError('nested compositor exited; see compositor.log')
      try:
        instances = json.loads(self._hyprctl('instances', '-j'))
      except (ValueError, subprocess.SubprocessError):
        instances = []
      if instances:
        self.env['HYPRLAND_INSTANCE_SIGNATURE'] = instances[0]['instance']
        self.env['WAYLAND_DISPLAY'] = instances[0]['wl_socket']
        break
      time.sleep(.1)
    else:
      raise RuntimeError('nested compositor did not start')
    time.sleep(.3)
    self._listen()
    return self

  def __exit__(self, *exc):
    # Close every window and let it unmap before stopping the compositor:
    # tearing Hyprland down with windows (and groups) still mapped can crash it.
    for c in self._clients:
      c.terminate()
    for c in self._clients:
      try:
        c.wait(timeout=3)
      except subprocess.TimeoutExpired:
        c.kill()
    for _ in range(30):
      try:
        if not self.clients():
          break
      except (subprocess.SubprocessError, ValueError):
        break
      time.sleep(.1)
    self.compositor.terminate()
    try:
      self.compositor.wait(timeout=5)
    except subprocess.TimeoutExpired:
      self.compositor.kill()
    self.log.close()
    self._tmp.cleanup()

  # ----- control -----

  def _hyprctl(self, *argv):
    return subprocess.run(['hyprctl', *argv], env=self.env, capture_output=True, text=True, timeout=5, check=True).stdout

  def ctl(self, *argv):
    if argv[0] == 'plugin':
      sig = self.env.get('HYPRLAND_INSTANCE_SIGNATURE')
      if not sig or sig == self.parent_signature or self.env['XDG_RUNTIME_DIR'] != str(self.scratch):
        raise RuntimeError('refusing to send a plugin command outside the nested compositor')
    out = self._hyprctl(*argv)
    if out.startswith('Err') or "Couldn't" in out:
      raise RuntimeError(out)
    return out

  def load_plugin(self, path: Path):
    self.ctl('plugin', 'load', str(path))
    time.sleep(.2)

  def open_window(self, title='owl test', app_id='owl-test', cwd=None, command=('sleep', '120'), extra=()):
    """Opens a foot window; command=None runs the user's shell."""
    before = {c['address'] for c in self.clients()}
    argv = ['foot', '-o', 'resize-by-cells=no', *extra, f'--app-id={app_id}']
    if title:
      argv.append(f'--title={title}')
    if cwd:
      argv.append(f'--working-directory={cwd}')
    if command:
      argv += list(command)
    proc = subprocess.Popen(argv, env=self.env, stdout=self.log, stderr=self.log)
    self._clients.append(proc)
    for _ in range(60):
      new = [c for c in self.clients() if c['address'] not in before]
      if new:
        time.sleep(.3)
        return self.client(new[0]['address'])
      time.sleep(.1)
    raise RuntimeError('test window did not map')

  def start_shell(self, qml: Path, env: dict | None = None):
    """Runs the shell plugin on its own in Quickshell, with stand-in theme modules."""
    import shutil
    self.shell_dir = self.scratch / 'qs'
    shutil.copytree(HERE / 'qs-stub', self.shell_dir)
    shutil.copy(qml, self.shell_dir / qml.name)
    for helper in ('Settings.qml',):
      shutil.copy(qml.parent / helper, self.shell_dir / helper)
    # The repo's defaults, and settings of the test's own (none unless it writes some).
    self.settings_json = self.scratch / 'windows-like-settings.json'
    shell_env = dict(self.env, OMARCHY_WINDOWS_LIKE_ROOT=str(qml.parent), OMARCHY_WINDOWS_LIKE_SETTINGS_JSON=str(self.settings_json),
                     **(env or {}))
    self.shell_log = (self.artifacts / 'shell.log').open('w')
    proc = subprocess.Popen(['qs', '-p', str(self.shell_dir)], env=shell_env, stdout=self.shell_log, stderr=self.shell_log)
    self._clients.append(proc)
    for _ in range(50):
      try:
        if self.ipc('state'):
          return
      except subprocess.SubprocessError:
        pass
      time.sleep(.2)
    raise RuntimeError('shell did not start; see shell.log')

  def ipc(self, *argv):
    out = subprocess.run(['qs', '-p', str(self.shell_dir), 'ipc', 'call', 'windowslike', *argv], env=self.env,
                         capture_output=True, text=True, timeout=5, check=True).stdout.strip()
    return json.loads(out) if out.startswith('{') else out

  def clients(self):
    return json.loads(self.ctl('clients', '-j'))

  def client(self, address):
    return next(c for c in self.clients() if c['address'] == address)

  @property
  def width(self):
    return self.size()[0]

  @property
  def height(self):
    return self.size()[1]

  def size(self):
    """The nested screen's logical size, read fresh: it depends on the window the
    parent session gives the compositor and changes when a config reload
    re-applies the monitor rule."""
    monitor = json.loads(self.ctl('monitors', '-j'))[0]
    return round(monitor['width'] / monitor['scale']), round(monitor['height'] / monitor['scale'])

  def pointer(self, commands):
    width, height = self.size()
    subprocess.run([str(self.scratch / 'pointer'), str(width), str(height)], input='\n'.join(commands) + '\n', text=True,
                   env=self.env, check=True, timeout=20)
    time.sleep(.2)

  def drag(self, start, *points, steps=20):
    """Presses at start, moves through each point in turn, and releases."""
    sx, sy = start
    commands = [f'move {sx} {sy}', 'wait 100', 'down', 'wait 120']
    for ex, ey in points:
      for i in range(1, steps + 1):
        commands += [f'move {round(sx + (ex - sx) * i / steps)} {round(sy + (ey - sy) * i / steps)}', 'wait 20']
      sx, sy = ex, ey
    commands += ['wait 100', 'up', 'wait 100']
    self.pointer(commands)

  def shortcut(self, *keys):
    """Holds each key but the last, taps the last: shortcut('Control_L', 'Shift_L', 'Tab')."""
    *mods, last = keys
    lines = [f'down {m}' for m in mods] + [f'tap {last}'] + [f'up {m}' for m in reversed(mods)]
    subprocess.run([str(self.scratch / 'keyboard')], input='\n'.join(lines) + '\n', text=True, env=self.env, check=True, timeout=10)
    time.sleep(.3)

  def key(self, *args):
    """Types with wtype, e.g. key('-M', 'ctrl', 't', '-m', 'ctrl') or key('ls\n')."""
    subprocess.run(['wtype', *args], env=self.env, check=True, timeout=10)
    time.sleep(.3)

  def capture(self, name):
    monitor = json.loads(self.ctl('monitors', '-j'))[0]['name']
    subprocess.run(['grim', '-o', monitor, str(self.artifacts / f'{name}.png')], env=self.env, check=True)

  # ----- IPC events -----

  def _listen(self):
    path = self.scratch / 'hypr' / self.env['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket2.sock'
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(path))

    def run():
      buf = b''
      while True:
        try:
          chunk = sock.recv(4096)
        except OSError:
          return
        if not chunk:
          return
        buf += chunk
        *lines, buf = buf.split(b'\n')
        self.events.extend(line.decode(errors='replace') for line in lines)

    threading.Thread(target=run, daemon=True).start()

  def custom(self, prefix='windows-like:'):
    return [e[len('custom>>'):] for e in self.events if e.startswith('custom>>' + prefix)]
