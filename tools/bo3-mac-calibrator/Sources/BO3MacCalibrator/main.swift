import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid

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
    let dpi: Double
    let sensitivity: Double
    let turns: Double
    let fov: Double?
    let deviceFilter: String?
    let outputPath: String

    static let usage = """
    Usage:
      swift run -c release bo3-mac-calibrator \\
        --dpi <value> --sensitivity <value> [options]

    Required:
      --dpi <value>          Physical mouse DPI.
      --sensitivity <value>  Black Ops 3 hipfire sensitivity.

    Options:
      --turns <value>        Number of full rotations to perform (default: 10).
      --fov <value>          FOV used during the measurement (saved as metadata).
      --device <text>        Only capture a mouse whose product name contains text.
      --output <path>        JSON Lines output file (default: bo3-calibration.jsonl).
      --help                 Show this help.

    Hotkeys:
      Command+Shift+8  Start or stop a capture.
      Command+Shift+9  Quit.
      F8 / F9          Alternate capture / quit keys.
    """

    static func parse(_ arguments: [String]) throws -> Options {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }

        var dpi: Double?
        var sensitivity: Double?
        var turns = 10.0
        var fov: Double?
        var deviceFilter: String?
        var outputPath = "bo3-calibration.jsonl"
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
            case "--dpi":
                dpi = Double(try value(after: argument))
            case "--sensitivity":
                sensitivity = Double(try value(after: argument))
            case "--turns":
                guard let parsed = Double(try value(after: argument)) else {
                    throw CLIError.message("--turns must be a number.")
                }
                turns = parsed
            case "--fov":
                guard let parsed = Double(try value(after: argument)) else {
                    throw CLIError.message("--fov must be a number.")
                }
                fov = parsed
            case "--device":
                deviceFilter = try value(after: argument)
            case "--output":
                outputPath = try value(after: argument)
            default:
                throw CLIError.message("Unknown argument: \(argument)")
            }
            index += 1
        }

        guard let dpi, dpi > 0 else {
            throw CLIError.message("--dpi is required and must be greater than zero.")
        }
        guard let sensitivity, sensitivity > 0 else {
            throw CLIError.message("--sensitivity is required and must be greater than zero.")
        }
        guard turns > 0 else {
            throw CLIError.message("--turns must be greater than zero.")
        }
        if let fov, fov <= 0 {
            throw CLIError.message("--fov must be greater than zero.")
        }

        return Options(
            dpi: dpi,
            sensitivity: sensitivity,
            turns: turns,
            fov: fov,
            deviceFilter: deviceFilter,
            outputPath: outputPath
        )
    }
}

private struct CalibrationRecord: Codable {
    let timestamp: String
    let device: String
    let dpi: Double
    let sensitivity: Double
    let fov: Double?
    let turns: Double
    let netXCounts: Int64
    let absoluteXCounts: Int64
    let samples: Int64
    let countsPer360: Double
    let cmPer360: Double
    let yawCoefficient: Double
    let reversalPercent: Double
}

private final class Calibrator {
    private let options: Options
    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var eventTap: CFMachPort?
    private var hotkeyRunLoopSource: CFRunLoopSource?
    private var isCapturing = false
    private var netXCounts: Int64 = 0
    private var absoluteXCounts: Int64 = 0
    private var samples: Int64 = 0
    private var activeDeviceName: String?

    init(options: Options) {
        self.options = options
    }

    deinit {
        if let hotkeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), hotkeyRunLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func start() throws {
        let hidManager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )

        let mouseMatching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey as String: Int(kHIDUsage_GD_Mouse)
        ]
        IOHIDManagerSetDeviceMatching(hidManager, mouseMatching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, { context, _, _, value in
            guard let context else { return }
            let calibrator = Unmanaged<Calibrator>
                .fromOpaque(context)
                .takeUnretainedValue()
            calibrator.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            hidManager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let openResult = IOHIDManagerOpen(
            hidManager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard openResult == kIOReturnSuccess else {
            throw CLIError.message(
                "Could not open mouse HID devices (IOKit error \(openResult)). " +
                "Grant Input Monitoring permission and try again."
            )
        }
        manager = hidManager

        try installHotkeys()
        printIntroduction()
    }

    private func installHotkeys() throws {
        let promptOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(promptOptions) else {
            throw CLIError.message(
                "Accessibility permission is required. Approve Terminal (or this " +
                "executable), completely restart it, and run again."
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
                return calibrator.handleHotkey(event)
                    ? nil
                    : Unmanaged.passUnretained(event)
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
        hotkeyRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleHotkey(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags

        if keyCode == Int(kVK_F8) ||
            (keyCode == Int(kVK_ANSI_8) &&
             flags.contains(.maskCommand) && flags.contains(.maskShift)) {
            if !isRepeat { toggleCapture() }
            return true
        }

        if keyCode == Int(kVK_F9) ||
            (keyCode == Int(kVK_ANSI_9) &&
             flags.contains(.maskCommand) && flags.contains(.maskShift)) {
            if !isRepeat { quit() }
            return true
        }

        return false
    }

    private func printIntroduction() {
        print("BO3 Mac raw-count calibrator")
        print("DPI: \(format(options.dpi, decimals: 3))")
        print("Sensitivity: \(format(options.sensitivity, decimals: 9))")
        print("Turns per capture: \(format(options.turns, decimals: 3))")
        if let fov = options.fov {
            print("FOV metadata: \(format(fov, decimals: 3))")
        }
        if let filter = options.deviceFilter {
            print("Mouse filter: \(filter)")
        }
        print("Output: \(expandedOutputPath)")
        print("")
        print("Press Command+Shift+8, perform exactly " +
              "\(format(options.turns, decimals: 3)) full turns in one direction, " +
              "then press Command+Shift+8 again.")
        print("Press Command+Shift+9 to quit. F8/F9 are alternate hotkeys.")
        print("No mouse input is generated or modified.")
        print("")
        fflush(stdout)
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_GenericDesktop),
              IOHIDElementGetUsage(element) == UInt32(kHIDUsage_GD_X) else {
            return
        }
        let device = IOHIDElementGetDevice(element)

        let deviceName = (IOHIDDeviceGetProperty(
            device,
            kIOHIDProductKey as CFString
        ) as? String) ?? "Unknown mouse"

        if let filter = options.deviceFilter,
           !deviceName.localizedCaseInsensitiveContains(filter) {
            return
        }

        let delta = Int64(IOHIDValueGetIntegerValue(value))
        guard delta != 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard isCapturing else { return }

        if activeDeviceName == nil {
            activeDeviceName = deviceName
            print("Capturing mouse: \(deviceName)")
            fflush(stdout)
        }
        guard activeDeviceName == deviceName else { return }

        netXCounts += delta
        absoluteXCounts += abs(delta)
        samples += 1
    }

    private func toggleCapture() {
        lock.lock()
        if !isCapturing {
            netXCounts = 0
            absoluteXCounts = 0
            samples = 0
            activeDeviceName = nil
            isCapturing = true
            lock.unlock()
            print("\nCAPTURE STARTED — turn in one direction now.")
            NSSound.beep()
            fflush(stdout)
            return
        }

        isCapturing = false
        let capturedNetX = netXCounts
        let capturedAbsoluteX = absoluteXCounts
        let capturedSamples = samples
        let capturedDevice = activeDeviceName ?? "Unknown mouse"
        lock.unlock()

        NSSound.beep()
        report(
            netX: capturedNetX,
            absoluteX: capturedAbsoluteX,
            sampleCount: capturedSamples,
            deviceName: capturedDevice
        )
    }

    private func report(
        netX: Int64,
        absoluteX: Int64,
        sampleCount: Int64,
        deviceName: String
    ) {
        let netMagnitude = abs(Double(netX))
        guard netMagnitude > 0 else {
            print("\nCAPTURE STOPPED — no horizontal raw counts were recorded.")
            print("Check Input Monitoring permission or use --device to select your mouse.")
            fflush(stdout)
            return
        }

        let countsPer360 = netMagnitude / options.turns
        let cmPer360 = countsPer360 / options.dpi * 2.54
        let yawCoefficient = 360.0 / (countsPer360 * options.sensitivity)
        let reversalPercent: Double
        if absoluteX > 0 {
            reversalPercent = max(
                0,
                (Double(absoluteX) - netMagnitude) / Double(absoluteX) * 100.0
            )
        } else {
            reversalPercent = 0
        }

        print("\nCAPTURE STOPPED")
        print("Device: \(deviceName)")
        print("Net X counts: \(abs(netX))")
        print("Absolute X counts: \(absoluteX)")
        print("Input samples: \(sampleCount)")
        print("Counts/360: \(format(countsPer360, decimals: 6))")
        print("cm/360: \(format(cmPer360, decimals: 6))")
        print("Yaw coefficient: \(format(yawCoefficient, decimals: 12))")
        print("Direction reversal: \(format(reversalPercent, decimals: 3))%")

        if reversalPercent > 1.0 {
            print("Warning: reversal exceeded 1%. Repeat with a steadier one-direction turn.")
        }

        let record = CalibrationRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            device: deviceName,
            dpi: options.dpi,
            sensitivity: options.sensitivity,
            fov: options.fov,
            turns: options.turns,
            netXCounts: netX,
            absoluteXCounts: absoluteX,
            samples: sampleCount,
            countsPer360: countsPer360,
            cmPer360: cmPer360,
            yawCoefficient: yawCoefficient,
            reversalPercent: reversalPercent
        )

        do {
            try append(record: record)
            print("Saved: \(expandedOutputPath)")
        } catch {
            print("Could not save calibration: \(error)")
        }
        print("Press Command+Shift+8 to capture again or Command+Shift+9 to quit.\n")
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
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
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
