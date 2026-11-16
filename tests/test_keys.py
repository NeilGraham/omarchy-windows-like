"""Tapping Super alone opens Start; Super + anything else doesn't; the setting
turns it off.

Usage: python -I tests/test_keys.py native/drag-events/drag-events.so [artifacts-dir]
"""
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nested import Nested  # noqa: E402

plugin = Path(sys.argv[1]).resolve()
artifacts = Path(sys.argv[2] if len(sys.argv) > 2 else '/tmp/owl-test-keys')
artifacts.mkdir(parents=True, exist_ok=True)
settings_lua = artifacts / 'settings.lua'

EXTRA = f'''
o = o or {{
  bind = function(keys, desc, action, opts) hl.bind(keys, action, opts or {{ description = desc }}) end,
  rebind = function(keys, desc, action, opts) hl.bind(keys, action, opts or {{ description = desc }}) end,
}}
dofile("{HERE.parent / 'hypr' / 'windows-like.lua'}")
'''


def start_events(n):
  return [e for e in n.custom('windows-like-start')]


def run(superOpens):
  settings_lua.write_text('return { start = { superOpens = %s } }\n' % ('true' if superOpens else 'false'))
  with Nested(artifacts, extra_config=EXTRA, extra_env={'OMARCHY_WINDOWS_LIKE_NATIVE': str(plugin),
                                                        'OMARCHY_WINDOWS_LIKE_SETTINGS': str(settings_lua)}) as n:
    assert not n.ctl('configerrors').strip(), n.ctl('configerrors')
    w = n.open_window()
    n.ctl('dispatch', f'hl.dsp.focus({{ window = "address:{w["address"]}" }})')
    time.sleep(.3)

    n.events.clear()
    n.shortcut('Super_L')  # a clean tap
    time.sleep(.4)
    tapped = start_events(n)

    n.events.clear()
    n.shortcut('Super_L', 'z')  # Super + Z: its own bind, not Start
    time.sleep(.4)
    combo = start_events(n)
    toggles = n.custom('windows-like-toggle')

    n.events.clear()
    n.shortcut('Super_L', 'Alt_L', 'space')
    time.sleep(.4)
    apps = n.custom('windows-like-start-apps')
    return tapped, combo, toggles, apps


tapped, combo, toggles, apps = run(True)
assert tapped == ['windows-like-start'], tapped
print('PASS: tapping Super opens Start', flush=True)
assert combo == [] and toggles == ['windows-like-toggle'], (combo, toggles)
print('PASS: Super + Z does its own thing, not Start', flush=True)
assert apps == ['windows-like-start-apps'], apps
print('PASS: Super + Alt + Space opens All apps', flush=True)

tapped, _, _, _ = run(False)
assert tapped == [], tapped
print('PASS: start.superOpens = false leaves Super alone', flush=True)
print('ALL PASS', flush=True)
