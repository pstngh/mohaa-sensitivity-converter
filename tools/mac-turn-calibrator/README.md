# macOS deterministic turn calibrator

This command-line tool generates exact horizontal mouse deltas so you can
measure an unknown game's hipfire sensitivity without physically moving a
mouse. It is game-independent and records counts/360, cm/360, and the effective
yaw coefficient.

## Compatibility

The tool uses macOS Core Graphics mouse events. It works only when the game
accepts synthetic macOS mouse movement. A game that reads a physical mouse
directly through raw HID may ignore the generated movement; software alone
cannot bypass that boundary reliably.

Use this only in an offline, private, or bot match. Close the tool before normal
gameplay.

## Requirements

- macOS 11 or later;
- Xcode Command Line Tools (`xcode-select --install`);
- Accessibility permission for Terminal or the compiled executable under
  **System Settings -> Privacy & Security -> Accessibility**.

The first run prompts for Accessibility access. After granting it, completely
quit Terminal, reopen it, and run the command again.

## Build and run

Open Terminal in this directory. For example:

```bash
swift run -c release mac-turn-calibrator \
  --game "Black Ops 3" \
  --sensitivity 2 \
  --dpi 1600 \
  --fov 80
```

`--sensitivity`, `--dpi`, and `--fov` are optional metadata. The generated
counts/360 measurement does not depend on them.

## Controls

The hotkeys work while the game is focused and are suppressed before reaching
the game:

| Key | Action |
| --- | --- |
| F8 | Reset the total to zero |
| Right / Left | Add / subtract 1 count |
| Shift + Right / Left | Add / subtract 10 counts |
| Option + Right / Left | Add / subtract 100 counts |
| Command + Right / Left | Add / subtract 1000 counts |
| Return | Save the completed rotation |
| F9 | Quit |

Holding an arrow uses normal keyboard repeat. Start with Command for coarse
movement, then use Option, Shift, and the unmodified arrows to align precisely.

## Calibration procedure

1. Disable mouse acceleration, smoothing, and filtering in the game if possible.
2. Pick a distinct vertical landmark and place the crosshair on it.
3. Run the calibrator and focus the game.
4. Press F8 to reset the total.
5. Use the right arrow and its modifiers until the view is nearly one rotation.
6. Use left/right with smaller steps until the crosshair returns to the exact
   starting landmark.
7. Press Return. The tool saves `mac-turn-calibration.jsonl`.
8. Repeat in both directions and at multiple packet sizes to validate the result.

For greater visual precision, use `--turns 10`, align ten full rotations, and
press Return. The program divides the generated total by ten.

## Packet timing and acceleration

By default, movements larger than 100 counts are split into 100-count events,
4 milliseconds apart. These settings are saved with every result:

```bash
swift run -c release mac-turn-calibrator \
  --game "Black Ops 3" \
  --sensitivity 2 \
  --packet-size 25 \
  --interval-ms 8
```

If results change when packet size or interval changes, the game or macOS is
applying acceleration. There is then no single pixel-perfect sensitivity value
until that acceleration is disabled or the packet timing is held constant.

## Reading the result

- **generatedCounts** is the exact signed total requested from macOS. It cannot
  prove that a game accepted every generated event, so verify the visual return
  to the starting landmark.
- **countsPer360** is `abs(generatedCounts) / turns`.
- **cmPer360** is calculated only when `--dpi` is supplied.
- **yawCoefficient** is `360 / (countsPer360 * sensitivity)` and is calculated
  only when `--sensitivity` is supplied.

Screen pixels are not counted. Perspective projection makes pixels-per-degree
vary with FOV and screen position, while input counts per complete rotation are
the stable quantity needed for sensitivity conversion.
