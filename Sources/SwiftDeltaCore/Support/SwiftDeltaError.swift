//===--- SwiftDeltaError.swift - SwiftDelta ------------------------------------------===//
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

public enum SwiftDeltaError: LocalizedError, Sendable {
    case invalidRoot(String)
    case invalidConfiguration(field: String, reason: String)
    case ambiguousSelection(kind: String, choices: [String])
    case missingSelection(String)
    case unsafePath(String)
    case fileTooLarge(path: String, limit: Int)
    case processLaunch(executable: String, reason: String)
    case processTimedOut(executable: String, seconds: TimeInterval)
    case processCancelled(executable: String)
    case processFailed(executable: String, status: Int32, message: String)
    case invalidXcodePath(String)
    case buildFailed(xcode: String, status: Int32, diagnostics: [CompilerDiagnostic])
    case offlineDependencyUnavailable(String)
    case outputWrite(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRoot(path):
            "The project root does not exist or is not a directory: \(path)"
        case let .invalidConfiguration(field, reason):
            "Invalid configuration field '\(field)': \(reason)"
        case let .ambiguousSelection(kind, choices):
            "Multiple \(kind) values were found. Select one explicitly: \(choices.joined(separator: ", "))"
        case let .missingSelection(description):
            "A required selection is missing: \(description)"
        case let .unsafePath(path):
            "The path is outside the permitted project root: \(path)"
        case let .fileTooLarge(path, limit):
            "The file exceeds the \(limit)-byte analysis limit: \(path)"
        case let .processLaunch(executable, reason):
            "Could not start \(executable): \(reason)"
        case let .processTimedOut(executable, seconds):
            "\(executable) exceeded the \(Int(seconds))-second timeout."
        case let .processCancelled(executable):
            "\(executable) was cancelled."
        case let .processFailed(executable, status, message):
            "\(executable) exited with status \(status): \(message)"
        case let .invalidXcodePath(path):
            "The Xcode path is not a usable Xcode application: \(path)"
        case let .buildFailed(xcode, status, diagnostics):
            if let cause = diagnostics.first(where: { $0.severity == .error })
                ?? diagnostics.first
            {
                "The project build with \(xcode) failed with status \(status). "
                    + cause.message
            } else {
                "The project build with \(xcode) failed with status \(status)."
            }
        case let .offlineDependencyUnavailable(message):
            "Offline dependency blocker: \(message)"
        case let .outputWrite(path, reason):
            "Could not write the report to \(path): \(reason)"
        }
    }
}

extension DecodingError {
    var swiftDeltaDescription: (field: String, reason: String) {
        switch self {
        case let .keyNotFound(key, context):
            return ((context.codingPath + [key]).map(\.stringValue).joined(separator: "."), context.debugDescription)
        case let .typeMismatch(_, context),
             let .valueNotFound(_, context),
             let .dataCorrupted(context):
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return (field.isEmpty ? "<root>" : field, context.debugDescription)
        @unknown default:
            return ("<root>", localizedDescription)
        }
    }
}
