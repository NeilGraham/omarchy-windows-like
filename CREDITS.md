# Credits

Everything here is under the [MIT license](LICENSE), and builds on the
following MIT-licensed work.

## omarchy-snap-layouts

`WindowsLike.qml` started from `SnapLayouts.qml` in
[n0rthstar88/omarchy-snap-layouts](https://github.com/n0rthstar88/omarchy-snap-layouts):
the layout picker, the zone geometry, and snap assist. Drag detection was
replaced (see `native/drag-events/`), and edge, corner, maximize and
full-height snapping were added.

```text
MIT License

Copyright (c) 2026 n0rthstar88

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## omarchy-hyprland-titlebars

`tests/pointer.c` and `tests/wlr-virtual-pointer-unstable-v1.xml` (the virtual
pointer that drives the nested test compositor) come from the `tools/` folder of
[omacom/omarchy-hyprland-titlebars](https://github.com/omacom/omarchy-hyprland-titlebars),
which is Omarchy's own code under its MIT license (`LICENSE.MIT` there).
`tests/nested.py` follows the approach of its `tools/verify.py`.

```text
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Omarchy

- `assets/omarchy-mark.svg` is the Omarchy mark from
  https://omarchy.org/brand/omarchy-logo.svg (recolored white so the taskbar
  can tint it); the mark belongs to the Omarchy project.
- `TaskbarModel.js`'s `claimingEntryId` and the minimized-window convention
  follow Omarchy's dock (`shell/plugins/dock/DockModel.js`), and the taskbar
  brings windows forward the way the dock does. Omarchy is MIT licensed,
  Copyright (c) David Heinemeier Hansson.
- Windows-like Settings (`app/`) follows Omarchy's app templates (Omacut,
  Monologue): its theme and language handling are copied from them; see
  `app/LICENSE`.
