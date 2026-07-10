# Black Ops 3 Mac raw-count calibrator

This passive macOS command-line tool measures raw horizontal mouse counts while
you manually turn in Black Ops 3. It calculates:

- raw counts per 360°;
- physical cm/360 from the configured mouse DPI;
- the game's effective yaw coefficient for the chosen sensitivity;
- how much direction reversal occurred during the measurement.

It does **not** move the mouse, inject input, modify input, or automate gameplay.

## Requirements

- macOS 11 or later;
- Xcode Command Line Tools (`xcode-select --install`);
- a mouse with a known DPI;
- permission for Terminal (or the built executable) under:
  - **System Settings → Privacy & Security → Input Monitoring**;
  - **System Settings → Privacy & Security → Accessibility**.

The Accessibility permission is needed for the F8/F9 hotkeys while Black Ops 3
is focused. Input Monitoring allows the tool to observe raw HID counts.

## Build and run

Open Terminal in this directory and run:

```bash
swift run -c release bo3-mac-calibrator \
  --dpi 1600 \
  --sensitivity 2 \
  --fov 80 \
  --turns 10
```

If more than one mouse-like device is detected, filter by part of the product
name:

```bash
swift run -c release bo3-mac-calibrator \
  --dpi 1600 \
  --sensitivity 2 \
  --fov 80 \
  --turns 10 \
  --device "Logitech"
```

## Measurement procedure

1. Set the mouse to a fixed, known DPI.
2. In Black Ops 3, disable mouse acceleration, smoothing, and filtering if those
   options are available.
3. Use a reproducible hipfire view and note the sensitivity and FOV.
4. Start the calibrator, then focus Black Ops 3.
5. Press **F8**.
6. Turn in one direction for exactly the number of rotations supplied with
   `--turns`. Ten rotations substantially reduces alignment error.
7. Press **F8** again.
8. Press **F9** to quit, or repeat the capture.

On keyboards where the function row controls media features, hold **Fn** while
pressing F8 or F9.

Each completed capture is appended to `bo3-calibration.jsonl`. Send that file
back for analysis and integration into the sensitivity converter.

## Validation matrix

Run at least these measurements:

| Test | Sensitivity | FOV | Movement speed |
| --- | ---: | ---: | --- |
| A | low | normal | slow |
| B | high | normal | slow |
| C | low | normal | fast |
| D | low | alternate | slow |

The resulting yaw coefficients should agree closely:

- If A and B differ, the sensitivity scale is nonlinear or quantized.
- If A and C differ, acceleration is active.
- If A and D differ, FOV changes the hipfire turn scale.
- A direction-reversal warning means the physical turn was not steady enough.

## Why raw counts instead of screen pixels?

Screen pixels depend on resolution, FOV, projection, and where an object is on
screen. Raw counts per 360° directly measures the game's rotational response and
is the correct input for an exact hipfire cm/360 conversion. A later converter
can separately offer monitor-distance matching when visual pixel displacement is
the desired metric.

## Troubleshooting

- **F8/F9 do nothing:** grant Accessibility permission, quit Terminal, and open
  it again.
- **No counts are recorded:** grant Input Monitoring permission and restart the
  tool. Try `--device` if multiple mouse devices are present.
- **Counts stop when the game opens:** verify the permission applies to the exact
  Terminal app or compiled executable being used.
- **Yaw differs between slow and fast tests:** acceleration is still active, so
  no single exact coefficient exists for that setup.
