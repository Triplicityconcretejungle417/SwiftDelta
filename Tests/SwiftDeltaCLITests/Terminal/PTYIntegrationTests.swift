//===--- PTYIntegrationTests.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
@testable import SwiftDelta
import XCTest

final class PTYIntegrationTests: XCTestCase {
    func testRealInteractiveLaunchResizeAndNormalExitRestoreTerminal()
        throws
    {
        let executable = try executableURL()
        let result = try runInPTY(executable: executable) { process, master, slave in
            var resized = winsize(
                ws_row: 31,
                ws_col: 112,
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            XCTAssertEqual(ioctl(slave, TIOCSWINSZ, &resized), 0)
            _ = kill(process.processIdentifier, SIGWINCH)
            Thread.sleep(forTimeInterval: 0.1)
            _ = Darwin.write(master, "qy", 2)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(TerminalControl.enterAlternateScreen))
        XCTAssertTrue(result.output.contains(TerminalControl.hideCursor))
        XCTAssertTrue(result.output.contains("SwiftDelta"))
        XCTAssertTrue(result.output.contains("Actions"))
        XCTAssertFalse(result.output.contains("[48;2;"))
        XCTAssertTrue(result.output.contains(TerminalControl.showCursor))
        XCTAssertTrue(result.output.contains(TerminalControl.leaveAlternateScreen))
        XCTAssertEqual(
            result.attributesBefore.c_lflag,
            result.attributesAfter.c_lflag
        )
    }

    func testRealMouseDoubleClickOpensAHomeDestination() throws {
        let executable = try executableURL()
        let result = try runInPTY(executable: executable) { _, master, _ in
            let click = "\u{1B}[<0;5;14M\u{1B}[<0;5;14m"
            _ = click.withCString {
                Darwin.write(master, $0, click.utf8.count)
            }
            Thread.sleep(forTimeInterval: 0.05)
            _ = click.withCString {
                Darwin.write(master, $0, click.utf8.count)
            }
            Thread.sleep(forTimeInterval: 0.15)
            _ = Darwin.write(master, "qy", 2)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Settings"))
        XCTAssertTrue(result.output.contains(TerminalControl.leaveAlternateScreen))
    }

    func testTerminationSignalRestoresTerminalAndExitsCleanly() throws {
        let executable = try executableURL()
        let result = try runInPTY(executable: executable) { process, _, _ in
            _ = kill(process.processIdentifier, SIGTERM)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(TerminalControl.showCursor))
        XCTAssertTrue(result.output.contains(TerminalControl.leaveAlternateScreen))
        XCTAssertEqual(
            result.attributesBefore.c_lflag,
            result.attributesAfter.c_lflag
        )
    }

    func testHangupSignalRestoresTerminalAndExitsCleanly() throws {
        let executable = try executableURL()
        let result = try runInPTY(executable: executable) { process, _, _ in
            _ = kill(process.processIdentifier, SIGHUP)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(TerminalControl.showCursor))
        XCTAssertTrue(result.output.contains(TerminalControl.leaveAlternateScreen))
        XCTAssertEqual(
            result.attributesBefore.c_lflag,
            result.attributesAfter.c_lflag
        )
    }

    func testControlCInterruptRestoresTerminalAndExitsCleanly() throws {
        let executable = try executableURL()
        let result = try runInPTY(executable: executable) { _, master, _ in
            var interrupt: UInt8 = 0x03
            XCTAssertEqual(Darwin.write(master, &interrupt, 1), 1)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(TerminalControl.showCursor))
        XCTAssertTrue(result.output.contains(TerminalControl.leaveAlternateScreen))
        XCTAssertEqual(
            result.attributesBefore.c_lflag,
            result.attributesAfter.c_lflag
        )
    }

    func testHelpVersionInvalidArgumentsAndNonTTYStartup() throws {
        let executable = try executableURL()
        let help = try runWithPipes(executable, ["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("USAGE: swiftdelta"))
        XCTAssertFalse(help.stdout.contains("<subcommand>"))

        let version = try runWithPipes(executable, ["-V"])
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout, "SwiftDelta 1.0.0\n")

        let invalid = try runWithPipes(executable, ["compare"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertTrue(invalid.stderr.contains("interactive application"))

        let nonTTY = try runWithPipes(executable, [])
        XCTAssertEqual(nonTTY.status, 2)
        XCTAssertTrue(nonTTY.stderr.contains("interactive terminal or PTY"))
    }

    private func executableURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let direct = directory.appendingPathComponent("swiftdelta")
            if FileManager.default.isExecutableFile(atPath: direct.path) {
                return direct
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("The swiftdelta executable is not available beside the test products.")
    }

    private func runInPTY(
        executable: URL,
        interaction: (Process, Int32, Int32) throws -> Void
    ) throws -> PTYResult {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(
            ws_row: 26,
            ws_col: 100,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            Darwin.close(master)
            Darwin.close(slave)
        }
        var before = termios()
        XCTAssertEqual(tcgetattr(slave, &before), 0)

        let standardInput = FileHandle(
            fileDescriptor: dup(slave),
            closeOnDealloc: true
        )
        let standardOutput = FileHandle(
            fileDescriptor: dup(slave),
            closeOnDealloc: true
        )
        let standardError = FileHandle(
            fileDescriptor: dup(slave),
            closeOnDealloc: true
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--safe-mode"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
        ]
        try process.run()
        try standardInput.close()
        try standardOutput.close()
        try standardError.close()
        let currentFlags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, currentFlags | O_NONBLOCK)
        var collected = Data()
        let startupDeadline = Date().addingTimeInterval(3)
        while process.isRunning,
              Date() < startupDeadline,
              !String(decoding: collected, as: UTF8.self).contains(
                  TerminalControl.enterAlternateScreen
              )
        {
            readAvailable(master, into: &collected)
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            String(decoding: collected, as: UTF8.self).contains(
                TerminalControl.enterAlternateScreen
            ),
            "The TUI did not initialize its alternate screen"
        )
        try interaction(process, master, slave)

        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline {
            readAvailable(master, into: &collected)
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            XCTFail("Interactive process did not exit after input")
        }
        process.waitUntilExit()
        var after = termios()
        XCTAssertEqual(tcgetattr(slave, &after), 0)
        readAvailable(master, into: &collected)
        return PTYResult(
            status: process.terminationStatus,
            output: String(decoding: collected, as: UTF8.self),
            attributesBefore: before,
            attributesAfter: after
        )
    }

    private func readAvailable(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func runWithPipes(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> PipeResult {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return PipeResult(
            status: process.terminationStatus,
            stdout: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            stderr: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct PTYResult {
    let status: Int32
    let output: String
    let attributesBefore: termios
    let attributesAfter: termios
}

private struct PipeResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
