# AerospaceSwipe app icon

## Problem

`AerospaceSwipe.app` has no `CFBundleIconFile`, so macOS shows it with the
generic blank/grid placeholder icon (visible in System Settings ›
Accessibility, next to AeroSpace's real icon).

## Design

Visually pair with AeroSpace's icon without copying it: same three-circle
family (pastel yellow/coral/green circles on a white rounded-square, each
circle's glyph a darker shade of its own fill), but swap AeroSpace's window
ops glyphs (−, ×, +) for swipe-gesture chevrons since this app's job is
switching workspaces by trackpad swipe, not tiling.

Colors sampled directly from `/Applications/AeroSpace.app`'s `AppIcon.icns`:
- yellow `#F3C04B`, coral `#EC6C5D`, green `#60C652`
- background: white rounded-square with the same soft drop shadow
- each glyph: same hue as its circle, ~42% brightness (dark shade), matching
  how AeroSpace derives its own glyph colors

Circle glyphs: left chevron (‹) on coral, right chevron (›) on green, and a
short horizontal 3-dot "steps" glyph on yellow (nods to the multi-step swipe
feature added in v1.1.0). Overlap/sizing/positions mirror AeroSpace's layout.

## Production

No design tool available this session — draw programmatically with Pillow:
1. Render at 1024×1024 (rounded-square bg, drop shadow, 3 circles, 3 glyphs)
   using bezier/arc primitives, anti-aliased via 4x supersampling.
2. Downsample to the 10 sizes `iconutil` requires (16/32/128/256/512, @1x/@2x)
   into an `.iconset` folder.
3. `iconutil -c icns` → `AppIcon.icns`.
4. Commit the generated `.icns` (binary asset) under a new `Resources/`
   source directory; do not commit the intermediate `.iconset` or PNGs.

## Integration

- `makefile`'s `bundle` target: copy `Resources/AppIcon.icns` into
  `$(APP_CONTENTS)/Resources/AppIcon.icns`, and add
  `CFBundleIconFile = AppIcon` (and `CFBundleIconName = AppIcon` to match
  AeroSpace's Info.plist) to the generated `Info.plist`.
- No other file changes. This does not affect app behavior, only its icon.

## Out of scope

- Not retroactively adding the icon to the already-tagged v1.0.0/v1.1.0
  release builds — those releases are built from history as it existed.
  This icon lands in the next commit/version going forward.
