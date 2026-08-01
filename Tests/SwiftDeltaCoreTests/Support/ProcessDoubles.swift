//===--- ProcessDoubles.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftDeltaCore

struct ProcessCall: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL?
    let timeout: TimeInterval
}

final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (ProcessCall) throws -> ProcessResult

    private let lock = NSLock()
    private let handler: Handler
    private var storedCalls: [ProcessCall] = []

    init(handler: @escaping Handler = { _ in
        ProcessResult(exitStatus: 0, standardOutput: Data(), standardError: Data())
    }) {
        self.handler = handler
    }

    var calls: [ProcessCall] {
        lock.withLock { storedCalls }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        let call = ProcessCall(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        lock.withLock {
            storedCalls.append(call)
        }
        if cancellation() {
            throw SwiftDeltaError.processCancelled(executable: executable)
        }
        return try handler(call)
    }
}

final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [ProcessCall] = []
    private let underlying = ProcessRunner()

    var calls: [ProcessCall] {
        lock.withLock { storedCalls }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        lock.withLock {
            storedCalls.append(
                ProcessCall(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    timeout: timeout
                )
            )
        }
        let result = try underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: cancellation
        )
        if result.exitStatus != 0,
           ProcessInfo.processInfo.environment[
               "SWIFTDELTA_TEST_PRINT_PROCESS_FAILURES"
           ] == "1"
        {
            print(
                "SYNTHETIC_PROCESS_FAILURE \(executable) "
                    + "status=\(result.exitStatus)\n"
                    + result.standardOutputString + "\n"
                    + result.standardErrorString
            )
        }
        return result
    }
}
