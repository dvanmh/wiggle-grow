# wiggle-grow

A CLI tool for X11 that makes the mouse cursor grow when wiggled, making it easier to locate on large or multiple monitors.

<!-- This should be ./preview/demo.mp4, but it's gitHub we're talking about -->
https://github.com/user-attachments/assets/a7981315-0d5e-4c98-bcb0-c87e47adc046

## Building

Requirements:

- X11 development libraries
- libXcursor development library
- libXi (XInput2) development library
- Zig (0.16.0)

```bash
zig build -Doptimize=ReleaseSafe
```

The binary will be located at `./zig-out/bin/wg`.

## Usage

Run the daemon:

```bash
./zig-out/bin/wg
```

Now give your mouse a wiggle and watch it grow!

### Options

- `-h, --help` : Show help message
- `-v, --version` : Show version
- `-m, --mode <mode>` : How to display the grown cursor (`window` or `cursor`, default: `window`)
- `-f, --fps <N>` : Animation frame rate (default: `60`)
- `-c, --cursor-size <N>` : Grown cursor size in pixels (default: `180`)
- `-g, --grow-duration <N>` : Growth animation duration in ms (default: `300`)
- `-s, --shrink-duration <N>` : Shrink animation duration in ms (default: `150`)
- `-H, --hold-duration <N>` : Time to stay grown before shrinking in ms (default: `75`)
- `-b, --grow-bezier <S>` : Cubic Bézier curve for growth (default: `easeInOut`)
- `-B, --shrink-bezier <S>` : Cubic Bézier curve for shrinking (default: `easeInOut`)

### Wiggle Detection Tuning

- `-w, --wiggle-detection-window <N>` : Time window for detection in ms (default: `750`)
- `-d, --min-wiggle-distance <N>` : Min distance in pixels (default: `3000`)
- `-n, --min-wiggle-flips <N>` : Min direction changes (default: `6`)
- `-V, --min-wiggle-velocity <N>` : Min velocity in px/ms (default: `3.5`)

### Bézier Curves

Bézier curve format (used by `-b` and `-B`):

**Presets:**
`linear`, `ease`, `easeIn`, `easeOut`, `easeInOut`, `easeInSine`, `easeOutSine`, `easeInOutSine`, `easeInQuad`, `easeOutQuad`, `easeInOutQuad`, `easeInCubic`, `easeOutCubic`, `easeInOutCubic`, `easeInExpo`, `easeOutExpo`, `easeInOutExpo`, `easeInCirc`, `easeOutCirc`, `easeInOutCirc`, `sharp`, `decelerate`, `accelerate`, `swift`

**Custom:**
`<x1>,<y1>,<x2>,<y2>` (e.g., `0.25,0.1,0.25,1.0`)

## Display Modes

`wiggle-grow` supports two ways to display the grown cursor.

### Window Mode (Default)

This mode creates a transparent, click-through overlay window that follows your mouse.

- **Pros:**
  + Does not interfere with mouse input; you can still click and scroll while the cursor is growing/grown/shrinking.
  + Works even when other applications (games, application launchers like rofi, etc.) have an active pointer grab.
- **Cons:**
  + More resource intensive than cursor mode.
  + May have a very slight lag behind the actual cursor position.

#### Note for Compositor Users (picom)

If you use `picom`, add the following to the `rules` section in your `picom.conf` to prevent artifacts like shadows, blur, or fading on the overlay window:

```
{
  match = "class_g = 'WiggleGrow'";
  blur-background = false;
  corner-radius = 0;
  dim = 0;
  fade = false;
  opacity = 1;
  shadow = false;
}
```

### Cursor Mode

This mode uses the X11 cursor system to swap the hardware cursor with larger sprites.

- **Pros:**
  + Extremely efficient.
  + Perfectly synced with the hardware cursor.
- **Cons:**
  + Requires a pointer grab, which disables mouse buttons while growing/grown/shrinking.
  + Will not work if another application already has a pointer grab (game, application launcher like rofi, etc.).
  + Maximum grown size is capped by hardware/driver limits. Check yours with `xdpyinfo | grep -i 'largest cursor'`.
