//===--- TerminalSession.swift - SwiftDelta ------------------------------------------===//
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

private nonisolated(unsafe) var pendingTerminalSignal: Int32 = 0

private func recordTerminalSignal(_ signal: Int32) {
    // Signal handlers defer terminal cleanup to the normal event loop.
    pendingTerminalSignal = signal
}

final class TerminalSession {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let output: FileHandle
    private let mouseEnabled: Bool
    private var originalAttributes: termios?
    private var decoder = TerminalInputDecoder()
    private var queuedKeys: [TUIKey] = []
    private(set) var isOpen = false

    init(
        mouseEnabled: Bool,
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        output: FileHandle = .standardOutput
    ) {
        self.mouseEnabled = mouseEnabled
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.output = output
    }

    deinit {
        close()
    }

    static func isInteractive(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO
    ) -> Bool {
        isatty(inputDescriptor) == 1 && isatty(outputDescriptor) == 1
    }

    func open() throws {
        guard !isOpen else { return }
        guard Self.isInteractive(
            inputDescriptor: inputDescriptor,
            outputDescriptor: outputDescriptor
        ) else {
            throw LaunchError(
                "SwiftDelta requires an interactive terminal or PTY. "
                    + "Use --help or --version in non-interactive environments."
            )
        }
        var attributes = termios()
        guard tcgetattr(inputDescriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        originalAttributes = attributes
        var raw = attributes
        cfmakeraw(&raw)
        guard tcsetattr(inputDescriptor, TCSAFLUSH, &raw) == 0 else {
            originalAttributes = nil
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        installSignalHandlers()
        var sequence = TerminalControl.enterAlternateScreen
            + TerminalControl.hideCursor
            + TerminalControl.clearScreen
            + TerminalControl.move(row: 1, column: 1)
        if mouseEnabled {
            sequence += TerminalControl.enableMouse
        }
        output.write(Data(sequence.utf8))
        isOpen = true
    }

    func close() {
        guard isOpen || originalAttributes != nil else { return }
        if mouseEnabled {
            output.write(Data(TerminalControl.disableMouse.utf8))
        }
        output.write(
            Data(
                (
                    TerminalControl.reset
                        + TerminalControl.showCursor
                        + TerminalControl.leaveAlternateScreen
                ).utf8
            )
        )
        if var attributes = originalAttributes {
            _ = tcsetattr(inputDescriptor, TCSAFLUSH, &attributes)
        }
        originalAttributes = nil
        isOpen = false
        restoreSignalHandlers()
    }

    func size() -> TerminalSize {
        var value = winsize()
        if ioctl(outputDescriptor, TIOCGWINSZ, &value) == 0,
           value.ws_col > 0, value.ws_row > 0
        {
            return TerminalSize(
                columns: Int(value.ws_col),
                rows: Int(value.ws_row)
            )
        }
        let environment = ProcessInfo.processInfo.environment
        return TerminalSize(
            columns: Int(environment["COLUMNS"] ?? "") ?? 80,
            rows: Int(environment["LINES"] ?? "") ?? 24
        )
    }

    func readKey(timeoutMilliseconds: Int32 = 100) throws -> TUIKey? {
        if !queuedKeys.isEmpty {
            return queuedKeys.removeFirst()
        }
        if let signal = consumeSignal() {
            if signal == SIGWINCH {
                return nil
            }
            return signal == SIGINT ? .interrupt : .terminate
        }
        var descriptor = pollfd(
            fd: inputDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let status = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
        if status < 0 {
            if errno == EINTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status > 0, descriptor.revents & Int16(POLLIN) != 0 else {
            return decoder.flushPendingEscape()
        }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(inputDescriptor, &bytes, bytes.count)
        if count == 0 {
            return .terminate
        }
        guard count > 0 else {
            if errno == EINTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        queuedKeys.append(
            contentsOf: decoder.append(Array(bytes.prefix(count)))
        )
        return queuedKeys.isEmpty ? nil : queuedKeys.removeFirst()
    }

    private func installSignalHandlers() {
        pendingTerminalSignal = 0
        Darwin.signal(SIGINT, recordTerminalSignal)
        Darwin.signal(SIGTERM, recordTerminalSignal)
        Darwin.signal(SIGHUP, recordTerminalSignal)
        Darwin.signal(SIGQUIT, recordTerminalSignal)
        Darwin.signal(SIGWINCH, recordTerminalSignal)
    }

    private func restoreSignalHandlers() {
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
        Darwin.signal(SIGHUP, SIG_DFL)
        Darwin.signal(SIGQUIT, SIG_DFL)
        Darwin.signal(SIGWINCH, SIG_DFL)
        pendingTerminalSignal = 0
    }

    private func consumeSignal() -> Int32? {
        let value = pendingTerminalSignal
        pendingTerminalSignal = 0
        return value == 0 ? nil : value
    }
}
