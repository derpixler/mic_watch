#!/usr/bin/env swift
/**
 * mic_watch.swift
 *
 * Monitors the default audio input device (microphone) on macOS and notifies
 * a Raspberry Pi via HTTP when the microphone becomes active or inactive.
 * Designed to drive an "On Air" indicator lamp over the local network.
 *
 * Usage:  swift mic_watch.swift
 *         chmod +x mic_watch.swift && ./mic_watch.swift
 *
 * Requirements: macOS 12+, no external dependencies.
 */

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - .env Loader

/// Reads a `.env` file next to the script and returns its key-value pairs.
/// Skips blank lines, comments (#), and trims surrounding quotes from values.
func loadEnv() -> [String: String] {
    let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
    let envFile   = scriptDir.appendingPathComponent(".env")

    guard let content = try? String(contentsOf: envFile, encoding: .utf8) else {
        return [:]
    }

    var env: [String: String] = [:]
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
        let key   = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

        // Strip surrounding quotes (single or double)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }

        env[key] = value
    }
    return env
}

/// Resolves a config value: process environment → .env file → fallback.
func config(_ key: String, fallback: String, env: [String: String]) -> String {
    return ProcessInfo.processInfo.environment[key] ?? env[key] ?? fallback
}

// MARK: - Configuration

let dotenv = loadEnv()

/// Raspberry Pi host and port, assembled into base URL.
let piHost = config("PI_HOST", fallback: "localhost", env: dotenv)
let piPort = config("PI_PORT", fallback: "8080", env: dotenv)
let piBaseURL = "http://\(piHost):\(piPort)"

/// Polling interval in seconds.
let pollInterval = TimeInterval(config("POLL_INTERVAL", fallback: "0.5", env: dotenv)) ?? 0.5

/// Derived endpoint URLs – lamp on / lamp off.
let onURL  = URL(string: "\(piBaseURL)/on")!
let offURL = URL(string: "\(piBaseURL)/off")!

/// Directory for day-based session CSVs. Default: ~/Library/Application Support/mic_watch/sessions
let sessionLogDir: String = {
    let custom = config("SESSION_DIR", fallback: "", env: dotenv)
    if !custom.isEmpty { return (custom as NSString).expandingTildeInPath }
    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/mic_watch/sessions")
}()

/// Returns the CSV path for the given date (YYYY-MM-DD.csv).
func sessionLogPath(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let name = formatter.string(from: date) + ".csv"
    return (sessionLogDir as NSString).appendingPathComponent(name)
}

// MARK: - State

/// Tracks the last known microphone state to avoid redundant HTTP calls.
/// `nil` means "not yet determined" (first poll).
var lastMicActive: Bool? = nil

/// Running poll counter for log output.
var pollCount: UInt64 = 0

/// Timestamp when the current microphone session started. `nil` when inactive.
var sessionStart: Date? = nil

// MARK: - Logging

/// Prints a timestamped, human-readable log line.
/// Flushes stdout explicitly because LaunchAgent redirects it to a file
/// which causes block buffering – without fflush output never appears.
func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
}

// MARK: - Session Log (CSV)

/// ISO 8601 formatter shared across all session log writes.
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Ensures the session directory exists and the CSV for the given date has a header.
func ensureSessionLogHeader(path: String) {
    let fm = FileManager.default
    let dir = (path as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    if !fm.fileExists(atPath: path) ||
       (try? String(contentsOfFile: path, encoding: .utf8))?.isEmpty == true {
        try? "start,end,duration_min\n".write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Appends a completed session row to the day-based CSV.
func writeSession(start: Date, end: Date) {
    let seconds  = end.timeIntervalSince(start)
    let minutes  = (seconds / 60.0 * 10).rounded() / 10  // one decimal
    let path     = sessionLogPath(for: end)
    let line     = "\(isoFormatter.string(from: start)),\(isoFormatter.string(from: end)),\(minutes)\n"

    guard let data = line.data(using: .utf8) else { return }

    ensureSessionLogHeader(path: path)

    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    log("📝  Session recorded: \(isoFormatter.string(from: start)) → \(isoFormatter.string(from: end))  (\(minutes) min)")
}

/// Closes the current session (if any) and writes it to the CSV.
/// Clears `sessionStart` before writing so a signal handler that interrupts
/// between the two operations does not write the same session a second time.
func closeOpenSession() {
    guard let start = sessionStart else { return }
    sessionStart = nil
    writeSession(start: start, end: Date())
}

// MARK: - Signal Handling

/// Closes an open session and exits cleanly on SIGTERM / SIGINT.
func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        log("🛑  Received signal \(sig) – shutting down")
        closeOpenSession()
        removePidLock()
        exit(0)
    }
    signal(SIGTERM, handler)
    signal(SIGINT,  handler)
}

// MARK: - PID Lock

let pidFilePath = "/tmp/micwatch.pid"

/// Ensures only one instance of mic_watch runs at a time.
/// Writes the current PID to a lock file and kills any stale process
/// that may still be holding it.
func acquirePidLock() {
    let fm = FileManager.default
    let myPid = ProcessInfo.processInfo.processIdentifier

    if fm.fileExists(atPath: pidFilePath),
       let content = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       let existingPid = Int32(content) {

        if kill(existingPid, 0) == 0 {
            log("⚠️  Killing stale instance (PID \(existingPid))")
            kill(existingPid, SIGTERM)
            usleep(500_000)
        }
    }

    try? "\(myPid)\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
}

/// Removes the PID file on exit.
func removePidLock() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}

// MARK: - Audio Helpers

/// Returns the `AudioDeviceID` of the current default input device, or `nil`
/// when no input device is available / the query fails.
func defaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0, nil,
        &size,
        &deviceID
    )

    guard status == noErr else {
        log("⚠️  Failed to query default input device (OSStatus \(status))")
        return nil
    }

    if deviceID == kAudioDeviceUnknown {
        log("⚠️  No default input device available")
        return nil
    }

    return deviceID
}

/// Checks whether *any* process on the system is currently capturing audio
/// from the given device.
func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool? {
    var isRunning: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0, nil,
        &size,
        &isRunning
    )

    guard status == noErr else {
        log("⚠️  Failed to read running state for device \(deviceID) (OSStatus \(status))")
        return nil
    }

    return isRunning != 0
}

// MARK: - HTTP Notification

/// Shared URL session – reuses connections, no delegate needed.
let session = URLSession.shared

/// Sends a fire-and-forget GET request to the given URL.
/// Errors are logged but never propagated.
func notifyPi(url: URL) {
    let task = session.dataTask(with: url) { _, response, error in
        if let error = error {
            log("⚠️  HTTP request to \(url) failed: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            log("⚠️  Unexpected HTTP status \(http.statusCode) from \(url)")
        }
    }
    task.resume()
}

// MARK: - Main Loop

acquirePidLock()
installSignalHandlers()

log("🎙  mic_watch started (PID \(ProcessInfo.processInfo.processIdentifier)) – polling every \(pollInterval)s")
log("📡  Pi endpoint: \(piBaseURL)")
log("📝  Session log dir: \(sessionLogDir)")

/// `RunLoop` is required so `URLSession` callbacks are dispatched correctly
/// when running as a standalone script.
let runLoop = RunLoop.current
let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in

    guard let deviceID = defaultInputDeviceID() else {
        // Cannot determine device – close any open session and reset state
        // so the next successful poll triggers a notification.
        closeOpenSession()
        lastMicActive = nil
        return
    }

    guard let active = isDeviceRunning(deviceID) else {
        closeOpenSession()
        lastMicActive = nil
        return
    }

    pollCount += 1

    if active != lastMicActive {
        let endpoint = active ? onURL : offURL
        let label    = active ? "ON 🔴" : "OFF ⚪"

        if active {
            sessionStart = Date()
        } else {
            closeOpenSession()
        }

        log("🎤  Microphone state changed → \(label)  –  notifying \(endpoint)")
        notifyPi(url: endpoint)

        lastMicActive = active
    }
}

runLoop.add(timer, forMode: .default)
runLoop.run()
