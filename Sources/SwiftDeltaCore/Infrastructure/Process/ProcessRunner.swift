//===--- ProcessRunner.swift - SwiftDelta ------------------------------------------===//
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

public struct ProcessResult: Sendable {
    public let exitStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitStatus: Int32, standardOutput: Data, standardError: Data) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }

    public var safeErrorSummary: String {
        let source = standardError.isEmpty ? standardOutputString : standardErrorString
        return SecretRedactor.redact(String(source.prefix(8_192)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult
}

public extension ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 120
    ) throws -> ProcessResult {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: { false }
        )
    }
}

/// Runs tools without shell interpolation and captures their output in an
/// automatically removed private directory.
public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        let captureDirectory = try TemporaryDirectory(prefix: "swiftdelta-process")
        defer { captureDirectory.remove() }

        let standardOutputURL = captureDirectory.url.appendingPathComponent("stdout")
        let standardErrorURL = captureDirectory.url.appendingPathComponent("stderr")
        let isolatedHome = captureDirectory.url.appendingPathComponent(
            "Home",
            isDirectory: true
        )
        let isolatedTemporary = captureDirectory.url.appendingPathComponent(
            "Temporary",
            isDirectory: true
        )
        let isolatedCache = isolatedHome.appendingPathComponent(
            "Library/Caches",
            isDirectory: true
        )
        for directory in [isolatedHome, isolatedTemporary, isolatedCache] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)

        let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutputHandle.close()
            try? standardErrorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = sanitizedEnvironment(
            overrides: environment,
            isolatedHome: isolatedHome,
            isolatedTemporary: isolatedTemporary,
            isolatedCache: isolatedCache
        )
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        do {
            try process.run()
        } catch {
            throw SwiftDeltaError.processLaunch(
                executable: executable,
                reason: error.localizedDescription
            )
        }

        let start = Date()
        var terminationError: SwiftDeltaError?
        while process.isRunning {
            if cancellation() {
                terminationError = .processCancelled(executable: executable)
                terminate(process)
                break
            }
            if Date().timeIntervalSince(start) >= timeout {
                terminationError = .processTimedOut(executable: executable, seconds: timeout)
                terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try? standardOutputHandle.synchronize()
        try? standardErrorHandle.synchronize()

        if let terminationError {
            throw terminationError
        }

        return ProcessResult(
            exitStatus: process.terminationStatus,
            standardOutput: try Data(contentsOf: standardOutputURL, options: [.mappedIfSafe]),
            standardError: try Data(contentsOf: standardErrorURL, options: [.mappedIfSafe])
        )
    }

    private func sanitizedEnvironment(
        overrides: [String: String],
        isolatedHome: URL,
        isolatedTemporary: URL,
        isolatedCache: URL
    ) -> [String: String] {
        // Toolchain-selection variables are accepted only when the caller sets
        // them explicitly. Inheriting DEVELOPER_DIR or TOOLCHAINS could mix the
        // baseline and candidate toolchains.
        let inheritedKeys: Set<String> = ["LANG", "LC_ALL", "PATH"]
        let overrideKeys: Set<String> = [
            "CFFIXED_USER_HOME",
            "CLANG_MODULE_CACHE_PATH",
            "DEVELOPER_DIR",
            "HOME",
            "LANG",
            "LC_ALL",
            "PATH",
            "SDKROOT",
            "SWIFTPM_MODULECACHE_OVERRIDE",
            "TMPDIR",
            "TOOLCHAINS",
            "XDG_CACHE_HOME",
        ]
        var base = ProcessInfo.processInfo.environment.filter {
            inheritedKeys.contains($0.key)
        }
        base["PATH"] = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        base["HOME"] = isolatedHome.path
        base["CFFIXED_USER_HOME"] = isolatedHome.path
        base["TMPDIR"] = isolatedTemporary.path + "/"
        base["XDG_CACHE_HOME"] = isolatedCache.path
        return base.merging(
            overrides.filter { overrideKeys.contains($0.key) },
            uniquingKeysWith: { _, new in new }
        )
    }

    private func terminate(_ process: Process) {
        process.terminate()
        // Some toolchain processes ignore SIGTERM while unwinding. Escalation
        // keeps cancellation and timeout behavior bounded.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
