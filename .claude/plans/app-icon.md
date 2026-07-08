# AerospaceSwipe App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `AerospaceSwipe.app` a real icon so it stops showing macOS's generic blank-icon placeholder in Finder/System Settings.

**Architecture:** A one-off Python (Pillow) script renders the icon at 1024x1024 and downsamples it into the 10 sizes `iconutil` requires, which are combined into `Resources/AppIcon.icns` and committed as a binary asset. The `makefile`'s `bundle` target copies that `.icns` into the app bundle and adds `CFBundleIconFile`/`CFBundleIconName` to the generated `Info.plist`. The Python script itself is a build-time tool, not committed — only its `.icns` output is.

**Tech Stack:** Python 3 + Pillow (already installed), `iconutil` (built into macOS), GNU Make.

## Global Constraints

- Icon colors sampled from `/Applications/AeroSpace.app`'s real icon: yellow `#F3C04B`, coral `#EC6C5D`, green `#60C652` (per `.claude/specs/app-icon-design.md`).
- Each circle's glyph is a darker shade of its own circle color (~42% brightness), not a shared dark color.
- Glyphs: left chevron (‹) on the coral circle, right chevron (›) on the green circle, a 3-dot horizontal "steps" glyph on the yellow circle.
- White rounded-square background with soft drop shadow, same circle layout/overlap as AeroSpace's icon (yellow top-left, coral bottom-left, green right, all overlapping near center).
- Do not commit the generator script, the `.iconset` folder, or intermediate PNGs — only the final `Resources/AppIcon.icns`.
- Do not touch unrelated makefile targets, Info.plist keys, or app behavior.

---

### Task 1: Generate `Resources/AppIcon.icns`

**Files:**
- Create (temporary, not committed): `.claude/tmp/gen_icon.py`
- Create (committed): `Resources/AppIcon.icns`

**Interfaces:**
- Produces: a binary `.icns` file at `Resources/AppIcon.icns` containing image representations for sizes 16, 32, 128, 256, 512 at both @1x and @2x (10 PNGs total, per macOS's iconset naming convention).

- [ ] **Step 1: Write the icon generator script**

Create `.claude/tmp/gen_icon.py`:

```python
import math
from PIL import Image, ImageDraw

SIZE = 1024  # base canvas, supersampled 4x internally for AA
SS = 4
CANVAS = SIZE * SS

def darker(rgb, factor=0.42):
    return tuple(int(c * factor) for c in rgb)

YELLOW = (243, 192, 75)
CORAL = (236, 108, 93)
GREEN = (96, 198, 82)

def rounded_square(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)

def circle(draw, cx, cy, r, fill, alpha=235):
    bbox = (cx - r, cy - r, cx + r, cy + r)
    draw.ellipse(bbox, fill=fill + (alpha,))

def chevron(draw, cx, cy, size, color, direction, width):
    # direction: -1 = left, +1 = right
    half = size / 2
    if direction < 0:
        pts = [(cx + half, cy - size), (cx - half, cy), (cx + half, cy + size)]
    else:
        pts = [(cx - half, cy - size), (cx + half, cy), (cx - half, cy + size)]
    draw.line(pts, fill=color, width=width, joint="curve")
    r = width / 2
    for px, py in pts:
        draw.ellipse((px - r, py - r, px + r, py + r), fill=color)

def steps_glyph(draw, cx, cy, dot_r, gap, color):
    for i in (-1, 0, 1):
        x = cx + i * gap
        draw.ellipse((x - dot_r, cy - dot_r, x + dot_r, cy + dot_r), fill=color)

def render():
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # drop shadow layer
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    margin = int(CANVAS * 0.07)
    rounded_square(
        sd,
        (margin, margin + int(CANVAS * 0.02), CANVAS - margin, CANVAS - margin + int(CANVAS * 0.02)),
        radius=int(CANVAS * 0.22),
        fill=(0, 0, 0, 70),
    )
    shadow = shadow.filter(__import__("PIL.ImageFilter", fromlist=["ImageFilter"]).GaussianBlur(CANVAS * 0.02))
    img = Image.alpha_composite(img, shadow)

    # white rounded-square background
    bg = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bg)
    rounded_square(bd, (margin, margin, CANVAS - margin, CANVAS - margin), radius=int(CANVAS * 0.22), fill=(250, 250, 250, 255))
    img = Image.alpha_composite(img, bg)

    circles = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    cd = ImageDraw.Draw(circles)
    r = int(CANVAS * 0.225)
    cy_center = CANVAS * 0.52
    cx_center = CANVAS * 0.50
    yellow_c = (cx_center - r * 0.55, cy_center - r * 0.95)
    coral_c = (cx_center - r * 0.85, cy_center + r * 0.55)
    green_c = (cx_center + r * 0.65, cy_center + r * 0.05)

    circle(cd, *yellow_c, r, YELLOW)
    circle(cd, *coral_c, r, CORAL)
    circle(cd, *green_c, r, GREEN)
    img = Image.alpha_composite(img, circles)

    glyphs = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyphs)
    gw = int(CANVAS * 0.028)
    gsize = r * 0.42
    chevron(gd, *coral_c, gsize, darker(CORAL) + (255,), direction=-1, width=gw)
    chevron(gd, *green_c, gsize, darker(GREEN) + (255,), direction=1, width=gw)
    steps_glyph(gd, *yellow_c, dot_r=int(CANVAS * 0.018), gap=int(CANVAS * 0.05), color=darker(YELLOW) + (255,))
    img = Image.alpha_composite(img, glyphs)

    return img.resize((SIZE, SIZE), Image.LANCZOS)

def build_iconset(img, out_dir):
    import os
    os.makedirs(out_dir, exist_ok=True)
    sizes = [16, 32, 128, 256, 512]
    for s in sizes:
        img.resize((s, s), Image.LANCZOS).save(f"{out_dir}/icon_{s}x{s}.png")
        img.resize((s * 2, s * 2), Image.LANCZOS).save(f"{out_dir}/icon_{s}x{s}@2x.png")

if __name__ == "__main__":
    icon = render()
    build_iconset(icon, ".claude/tmp/AppIcon.iconset")
    print("iconset written to .claude/tmp/AppIcon.iconset")
```

- [ ] **Step 2: Run it**

Run: `python3 .claude/tmp/gen_icon.py`
Expected: prints `iconset written to .claude/tmp/AppIcon.iconset` and creates 10 PNGs under `.claude/tmp/AppIcon.iconset/`.

- [ ] **Step 3: Visually inspect the icon**

Use the Read tool on `.claude/tmp/AppIcon.iconset/icon_256x256@2x.png` (renders as an image). Confirm: white rounded-square, three overlapping circles (yellow top-left, coral bottom-left, green right), left chevron on coral, right chevron on green, 3-dot row on yellow, no clipping/artifacts. If something looks wrong (wrong overlap, glyph off-center, clipped edges), adjust the constants in Step 1 and re-run Step 2 — do not proceed until it looks right.

- [ ] **Step 4: Build the `.icns`**

Run: `mkdir -p Resources && iconutil -c icns .claude/tmp/AppIcon.iconset -o Resources/AppIcon.icns`
Expected: no output, `Resources/AppIcon.icns` exists (`ls -la Resources/AppIcon.icns` shows a non-zero-size file, typically 100-400KB).

- [ ] **Step 5: Commit the icon asset**

```bash
git add Resources/AppIcon.icns
git commit -m "feat: add AerospaceSwipe app icon"
```

---

### Task 2: Wire the icon into the app bundle

**Files:**
- Modify: `makefile` (the `bundle` target, currently `makefile:36-63` generating `$(INFO_PLIST)` and copying the binary/creating dirs)

**Interfaces:**
- Consumes: `Resources/AppIcon.icns` from Task 1.
- Produces: `$(APP_MACOS)/../Resources/AppIcon.icns` inside the built `.app`, and two new keys in the generated `Info.plist`: `CFBundleIconFile` = `AppIcon`, `CFBundleIconName` = `AppIcon`.

- [ ] **Step 1: Add the icon copy + Info.plist keys to the `bundle` target**

In `makefile`, the `bundle` target currently does (abridged):
```makefile
bundle: $(BINARY)
	@echo "Creating app bundle $(APP_BUNDLE)..."
	mkdir -p $(APP_MACOS)
	mkdir -p $(APP_CONTENTS)/Resources
	cp $(BINARY) $(APP_MACOS)/$(BINARY_NAME)
	@echo "Generating Info.plist..."
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(INFO_PLIST)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(INFO_PLIST)
	@echo '<plist version="1.0">' >> $(INFO_PLIST)
	@echo '<dict>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleExecutable</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleIdentifier</key>' >> $(INFO_PLIST)
	@echo '    <string>com.example.swipe</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleName</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleShortVersionString</key>' >> $(INFO_PLIST)
	@echo '    <string>$(VERSION)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleVersion</key>' >> $(INFO_PLIST)
	@echo '    <string>$(VERSION)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundlePackageType</key>' >> $(INFO_PLIST)
	@echo '    <string>APPL</string>' >> $(INFO_PLIST)
	@echo '    <key>NSPrincipalClass</key>' >> $(INFO_PLIST)
	@echo '    <string>NSApplication</string>' >> $(INFO_PLIST)
	@echo '    <key>LSUIElement</key>' >> $(INFO_PLIST)
	@echo '    <true/>' >> $(INFO_PLIST)
	@echo '</dict>' >> $(INFO_PLIST)
	@echo '</plist>' >> $(INFO_PLIST)
	@echo "APPL????" > $(APP_CONTENTS)/PkgInfo
	codesign --entitlements accessibility.entitlements --sign - $(APP_BUNDLE)
```

Change it to (adds one `cp` line after the `mkdir -p $(APP_CONTENTS)/Resources` line, and two plist keys before `CFBundlePackageType`):

```makefile
bundle: $(BINARY)
	@echo "Creating app bundle $(APP_BUNDLE)..."
	mkdir -p $(APP_MACOS)
	mkdir -p $(APP_CONTENTS)/Resources
	cp $(BINARY) $(APP_MACOS)/$(BINARY_NAME)
	cp Resources/AppIcon.icns $(APP_CONTENTS)/Resources/AppIcon.icns
	@echo "Generating Info.plist..."
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(INFO_PLIST)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(INFO_PLIST)
	@echo '<plist version="1.0">' >> $(INFO_PLIST)
	@echo '<dict>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleExecutable</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleIdentifier</key>' >> $(INFO_PLIST)
	@echo '    <string>com.example.swipe</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleName</key>' >> $(INFO_PLIST)
	@echo '    <string>$(BINARY_NAME)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleIconFile</key>' >> $(INFO_PLIST)
	@echo '    <string>AppIcon</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleIconName</key>' >> $(INFO_PLIST)
	@echo '    <string>AppIcon</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleShortVersionString</key>' >> $(INFO_PLIST)
	@echo '    <string>$(VERSION)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundleVersion</key>' >> $(INFO_PLIST)
	@echo '    <string>$(VERSION)</string>' >> $(INFO_PLIST)
	@echo '    <key>CFBundlePackageType</key>' >> $(INFO_PLIST)
	@echo '    <string>APPL</string>' >> $(INFO_PLIST)
	@echo '    <key>NSPrincipalClass</key>' >> $(INFO_PLIST)
	@echo '    <string>NSApplication</string>' >> $(INFO_PLIST)
	@echo '    <key>LSUIElement</key>' >> $(INFO_PLIST)
	@echo '    <true/>' >> $(INFO_PLIST)
	@echo '</dict>' >> $(INFO_PLIST)
	@echo '</plist>' >> $(INFO_PLIST)
	@echo "APPL????" > $(APP_CONTENTS)/PkgInfo
	codesign --entitlements accessibility.entitlements --sign - $(APP_BUNDLE)
```

- [ ] **Step 2: Build the bundle and verify**

Run: `rm -rf AerospaceSwipe.app swipe && make bundle`
Expected: builds cleanly, ends with `AerospaceSwipe.app: replacing existing signature` or similar codesign output (no error).

Then run: `plutil -p AerospaceSwipe.app/Contents/Info.plist | grep -i icon`
Expected:
```
  "CFBundleIconFile" => "AppIcon"
  "CFBundleIconName" => "AppIcon"
```

Then run: `ls -la AerospaceSwipe.app/Contents/Resources/AppIcon.icns`
Expected: file exists, non-zero size.

- [ ] **Step 3: Verify the icon actually renders**

Run: `qlmanage -p AerospaceSwipe.app -x 2>/dev/null &` (Quick Look preview) or open Finder to the repo and check the `.app`'s icon visually (`open -R AerospaceSwipe.app`). Confirm the icon shown is the new three-circle design, not the generic blank icon. This is the real acceptance check for the whole task — the plist keys alone don't prove Finder picked up the icon (icon caches can be stale; if it still looks blank, run `touch AerospaceSwipe.app && killall Finder` and re-check).

- [ ] **Step 4: Clean up build output and commit the makefile change**

```bash
rm -rf AerospaceSwipe.app swipe
git add makefile
git commit -m "build: bundle AppIcon.icns and set CFBundleIconFile"
```

---

### Task 3: Clean up generator artifacts

**Files:**
- Delete: `.claude/tmp/gen_icon.py`, `.claude/tmp/AppIcon.iconset/`, `.claude/tmp/aerospace_icon.iconset/`, `.claude/tmp/plus_zoom.png` (reference material pulled from AeroSpace.app during design, no longer needed)

- [ ] **Step 1: Remove temp files**

Run: `rm -rf .claude/tmp/gen_icon.py .claude/tmp/AppIcon.iconset .claude/tmp/aerospace_icon.iconset .claude/tmp/plus_zoom.png`
Expected: no output; `.claude/tmp/` is gitignored already so nothing to commit here.

- [ ] **Step 2: Confirm working tree is clean**

Run: `git status`
Expected: only untracked pre-existing items (e.g. `.codegraph/`, `test_*.dSYM/`), no icon-related leftovers.
