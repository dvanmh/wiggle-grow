# wiggle-grow

A CLI tool for X11 that makes the mouse cursor grow when wiggled, making it easier to locate on large or multiple monitors.

<video src="./preview/demo.mp4" controls></video>

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

**Note:** While the cursor is animating (growing, grown, or shrinking), mouse buttons are disabled (inputs are captured by the tool). Pressing any mouse button during this time will cause the cursor to start shrinking back to its original size immediately.

### Options

- `-h, --help` : Show help message
- `-v, --version` : Show version
- `-f, --fps <N>` : Animation frame rate (default: 60)
- `-c, --cursor-size <N>` : Grown cursor size in pixels (default: 180)
- `-g, --grow-duration <N>` : Growth animation duration in ms (default: 300)
- `-s, --shrink-duration <N>` : Shrink animation duration in ms (default: 150)
- `-H, --hold-duration <N>` : Time to stay grown before shrinking in ms (default: 75)
- `-b, --grow-bezier <S>` : Cubic Bézier curve for growth (default: easeInOut)
- `-B, --shrink-bezier <S>` : Cubic Bézier curve for shrinking (default: easeInOut)

### Wiggle Detection Tuning

- `-w, --wiggle-detection-window <N>` : Time window for detection in ms (default: 750)
- `-d, --min-wiggle-distance <N>` : Min distance in pixels (default: 3000)
- `-n, --min-wiggle-flips <N>` : Min direction changes (default: 6)
- `-V, --min-wiggle-velocity <N>` : Min velocity in px/ms (default: 3.5)

### Bézier Curves

Bézier curve format (used by `-b` and `-B`):

**Presets:**
`linear`, `ease`, `easeIn`, `easeOut`, `easeInOut`, `easeInSine`, `easeOutSine`, `easeInOutSine`, `easeInQuad`, `easeOutQuad`, `easeInOutQuad`, `easeInCubic`, `easeOutCubic`, `easeInOutCubic`, `easeInExpo`, `easeOutExpo`, `easeInOutExpo`, `easeInCirc`, `easeOutCirc`, `easeInOutCirc`, `sharp`, `decelerate`, `accelerate`, `swift`

**Custom:**
`<x1>,<y1>,<x2>,<y2>` (e.g., `0.25,0.1,0.25,1.0`)

## Limitation

The cursor will not grow if another application (such as a game or an application launcher like rofi) is already grabbing the mouse pointer, as the tool requires a successful pointer grab to display the grown cursor.
