import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct Options {
    let game: String
    let sensitivity: Double?
    let dpi: Double?
    let fov: Double?
    let turns: Double
    let packetSize: Int64
    let intervalMilliseconds: Double
    let outputPath: String

    static let usage = """
    Usage:
      swift run -c release mac-turn-calibrator [options]

    Options:
      --game <name>           Game name saved with the result (default: Unknown).
      --sensitivity <value>   In-game sensitivity, used to calculate yaw.
      --dpi <value>           Mouse DPI, used to calculate cm/360.
      --fov <value>           FOV saved as metadata.
      --turns <value>         Rotations aligned before saving (default: 1).
      --packet-size <counts>  Maximum delta in each generated event (default: 100).
      --interval-ms <value>   Delay between generated packets (default: 4).
      --output <path>         JSON Lines file (default: mac-turn-calibration.jsonl).
      --help                  Show this help.

    Global hotkeys while the calibrator is running:
      F8                     Reset the generated-count total.
      Right / Left           Generate +1 / -1 horizontal count.
      Shift + Right / Left   Generate +10 / -10 counts.
      Option + Right / Left  Generate +100 / -100 counts.
      Command + Right / Left Generate +1000 / -1000 counts.
      Return                 Save the current total as the requested rotation(s).
      F9                     Quit.
    """

    static func parse(_ arguments: [String]) throws -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }

        var game = "Unknown"
        var sensitivity: Double?
        var dpi: Double?
        var fov: Double?
        var turns = 1.0
        var packetSize: Int64 = 100
        var intervalMilliseconds = 4.0
        var outputPath = "mac-turn-calibration.jsonl"
        var index = 0

        func value(after flag: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CLIError.message("Missing value after \(flag).")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--game":
                game = try value(after: argument)
            case "--sensitivity":
                sensitivity = Double(try value(after: argument))
            case "--dpi":
                dpi = Double(try value(after: argument))
            case "--fov":
                fov = Double(try value(after: argument))
            case "--turns":
                guard let parsed = Double(try value(after: argument)) else {
                    throw CLIError.message("--turns must be a number.")
                }
                turns = parsed
            case "--packet-size":
                guard let parsed = Int64(try value(after: argument)) else {
                    throw CLIError.message("--packet-size must be a whole number.")
                }
                packetSize = parsed
            case "--interval-ms":
                guard let parsed = Double(try value(after: argument)) else {
                    throw CLIError.message("--interval-ms must be a number.")
                }
                intervalMilliseconds = parsed
            case "--output":
                outputPath = try value(after: argument)
            default:
                throw CLIError.message("Unknown argument: \(argument)")
            }
            index += 1
        }

        if let sensitivity, sensitivity <= 0 {
            throw CLIError.message("--sensitivity must be greater than zero.")
        }
        if let dpi, dpi <= 0 {
            throw CLIError.message("--dpi must be greater than zero.")
        }
        if let fov, fov <= 0 {
            throw CLIError.message("--fov must be greater than zero.")
        }
        guard turns > 0 else {
            throw CLIError.message("--turns must be greater than zero.")
        }
        guard packetSize > 0 else {
            throw CLIError.message("--packet-size must be greater than zero.")
        }
        guard intervalMilliseconds >= 0 else {
            throw CLIError.message("--interval-ms cannot be negative.")
        }

        return Options(
            game: game,
            sensitivity: sensitivity,
            dpi: dpi,
            fov: fov,
            turns: turns,
            packetSize: packetSize,
            intervalMilliseconds: intervalMilliseconds,
            outputPath: outputPath
        )
    }
}

private struct CalibrationRecord: Codable {
    let timestamp: String
    let game: String
    let sensitivity: Double?
    let dpi: Double?
    let fov: Double?
    let turns: Double
    let generatedCounts: Int64
    let countsPer360: Double
    let cmPer360: Double?
    let yawCoefficient: Double?
    let packetSize: Int64
    let intervalMilliseconds: Double
}

private final class Calibrator {
    private let options: Options
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var generatedCounts: Int64 = 0

    init(options: Options) {
        self.options = options
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    func start() throws {
        let promptOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        guard AXIsProcessTrustedWithOptions(promptOptions) else {
            throw CLIError.message(
                "Accessibility permission is required. Approve Terminal (or this " +
                "executable) in System Settings, restart it, and run again."
            )
        }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else {
                    return Unmanaged.passUnretained(event)
                }
                let calibrator = Unmanaged<Calibrator>
                    .fromOpaque(context)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = calibrator.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                if calibrator.handleKey(event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            throw CLIError.message(
                "Could not create the global hotkey event tap. Check Accessibility permission."
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw CLIError.message("Could not create the hotkey run-loop source.")
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        printIntroduction()
    }

    private func handleKey(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case Int(kVK_F8):
            reset()
        case Int(kVK_F9):
            quit()
        case Int(kVK_Return), Int(kVK_ANSI_KeypadEnter):
            finish()
        case Int(kVK_RightArrow):
            inject(direction: 1, flags: event.flags)
        case Int(kVK_LeftArrow):
            inject(direction: -1, flags: event.flags)
        default:
            return false
        }
        return true
    }

    private func multiplier(for flags: CGEventFlags) -> Int64 {
        if flags.contains(.maskCommand) { return 1000 }
        if flags.contains(.maskAlternate) { return 100 }
        if flags.contains(.maskShift) { return 10 }
        return 1
    }

    private func inject(direction: Int64, flags: CGEventFlags) {
        let requested = direction * multiplier(for: flags)
        var remaining = requested

        while remaining != 0 {
            let magnitude = min(abs(remaining), options.packetSize)
            let delta = remaining > 0 ? magnitude : -magnitude
            guard postMouseDelta(delta) else {
                NSSound.beep()
                print("Could not generate mouse delta; count total was not changed.")
                fflush(stdout)
                return
            }
            remaining -= delta

            if remaining != 0 && options.intervalMilliseconds > 0 {
                Thread.sleep(forTimeInterval: options.intervalMilliseconds / 1000.0)
            }
        }

        generatedCounts += requested
        print("Generated: \(signed(requested))    Total: \(signed(generatedCounts))")
        fflush(stdout)
    }

    private func postMouseDelta(_ delta: Int64) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let currentEvent = CGEvent(source: nil),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: currentEvent.location,
                mouseButton: .left
              ) else {
            return false
        }

        event.setIntegerValueField(.mouseEventDeltaX, value: delta)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        event.post(tap: .cghidEventTap)
        return true
    }

    private func reset() {
        generatedCounts = 0
        NSSound.beep()
        print("\nRESET — total generated counts: 0")
        fflush(stdout)
    }

    private func finish() {
        let magnitude = abs(Double(generatedCounts))
        guard magnitude > 0 else {
            NSSound.beep()
            print("\nNothing to save. Generate movement with the arrow keys first.")
            fflush(stdout)
            return
        }

        let countsPer360 = magnitude / options.turns
        let cmPer360 = options.dpi.map { countsPer360 / $0 * 2.54 }
        let yawCoefficient = options.sensitivity.map {
            360.0 / (countsPer360 * $0)
        }

        print("\nCALIBRATION COMPLETE")
        print("Game: \(options.game)")
        print("Generated counts: \(generatedCounts)")
        print("Turns: \(format(options.turns, decimals: 6))")
        print("Counts/360: \(format(countsPer360, decimals: 9))")
        if let cmPer360 {
            print("cm/360: \(format(cmPer360, decimals: 9))")
        }
        if let yawCoefficient {
            print("Yaw coefficient: \(format(yawCoefficient, decimals: 12))")
        }

        let record = CalibrationRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            game: options.game,
            sensitivity: options.sensitivity,
            dpi: options.dpi,
            fov: options.fov,
            turns: options.turns,
            generatedCounts: generatedCounts,
            countsPer360: countsPer360,
            cmPer360: cmPer360,
            yawCoefficient: yawCoefficient,
            packetSize: options.packetSize,
            intervalMilliseconds: options.intervalMilliseconds
        )

        do {
            try append(record: record)
            print("Saved: \(expandedOutputPath)")
        } catch {
            print("Could not save calibration: \(error)")
        }
        print("Press F8 to reset and begin another run, or F9 to quit.\n")
        NSSound.beep()
        fflush(stdout)
    }

    private func printIntroduction() {
        print("Mac deterministic turn calibrator")
        print("Game: \(options.game)")
        if let sensitivity = options.sensitivity {
            print("Sensitivity: \(format(sensitivity, decimals: 9))")
        }
        if let dpi = options.dpi {
            print("DPI: \(format(dpi, decimals: 3))")
        }
        if let fov = options.fov {
            print("FOV metadata: \(format(fov, decimals: 3))")
        }
        print("Turns per result: \(format(options.turns, decimals: 3))")
        print("Packet size: \(options.packetSize), interval: " +
              "\(format(options.intervalMilliseconds, decimals: 3)) ms")
        print("Output: \(expandedOutputPath)\n")
        print("F8 resets. Use Right/Left to align a full turn, then press Return.")
        print("Steps: plain=1, Shift=10, Option=100, Command=1000 counts.")
        print("F9 quits. Calibration hotkeys are suppressed before reaching the game.\n")
        fflush(stdout)
    }

    private var expandedOutputPath: String {
        NSString(string: options.outputPath).expandingTildeInPath
    }

    private func append(record: CalibrationRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)

        let url = URL(fileURLWithPath: expandedOutputPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func quit() {
        print("\nExiting calibrator.")
        fflush(stdout)
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func signed(_ value: Int64) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    private func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", decimals, value)
    }
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)

    let calibrator = Calibrator(options: options)
    try calibrator.start()
    RunLoop.main.run()
} catch {
    fputs("Error: \(error)\n\n\(Options.usage)\n", stderr)
    exit(EXIT_FAILURE)
}
