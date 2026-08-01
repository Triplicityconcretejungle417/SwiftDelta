//===--- SerializedDiagnosticReader.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import CDiagnosticReader
import Foundation

public struct StructuredDiagnosticFixIt: Hashable, Sendable {
    public let filePath: String
    public let sourceRange: RepairSourceRange
    public let replacementText: String
    public let diagnosticText: String
    public let diagnosticSeverity: Severity
    public let diagnosticIndex: Int
    public let fixItIndex: Int
    public let compilerContext: RepairCompilerContextEvidence?

    public init(
        filePath: String,
        sourceRange: RepairSourceRange,
        replacementText: String,
        diagnosticText: String,
        diagnosticSeverity: Severity,
        diagnosticIndex: Int,
        fixItIndex: Int,
        compilerContext: RepairCompilerContextEvidence? = nil
    ) {
        self.filePath = filePath
        self.sourceRange = sourceRange
        self.replacementText = replacementText
        self.diagnosticText = diagnosticText
        self.diagnosticSeverity = diagnosticSeverity
        self.diagnosticIndex = diagnosticIndex
        self.fixItIndex = fixItIndex
        self.compilerContext = compilerContext
    }
}

/// Decodes compiler-produced serialized diagnostics using the libclang shipped
/// inside the same selected Xcode. This avoids coupling fix-it interpretation
/// to the globally selected developer directory.
public struct SerializedDiagnosticReader: Sendable {
    public init() {}

    public func read(
        diagnosticsURL: URL,
        xcodeApplicationPath: String
    ) throws -> [StructuredDiagnosticFixIt] {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: xcodeApplicationPath
        )
        let libclang = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent(
                "Toolchains/XcodeDefault.xctoolchain/usr/lib/libclang.dylib"
            )
        guard FileManager.default.isReadableFile(atPath: libclang.path) else {
            throw RepairError.evidenceUnavailable(
                "the selected Xcode does not contain a readable libclang at \(libclang.path)"
            )
        }
        guard FileManager.default.isReadableFile(atPath: diagnosticsURL.path) else {
            throw RepairError.evidenceUnavailable(
                "the compiler did not produce serialized diagnostics at \(diagnosticsURL.path)"
            )
        }

        let box = FixItBox()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sd_load_diagnostic_fixits(
            libclang.path,
            diagnosticsURL.path,
            { filePath, startOffset, endOffset, startLine, startColumn,
                endLine, endColumn, replacement, diagnosticText, severity,
                diagnosticIndex, fixItIndex, context in
                guard let context else {
                    return
                }
                let box = Unmanaged<FixItBox>.fromOpaque(context)
                    .takeUnretainedValue()
                box.values.append(
                    StructuredDiagnosticFixIt(
                        filePath: filePath.map(String.init(cString:)) ?? "",
                        sourceRange: RepairSourceRange(
                            start: RepairSourcePosition(
                                line: Int(startLine),
                                column: Int(startColumn),
                                utf8Offset: Int(startOffset)
                            ),
                            end: RepairSourcePosition(
                                line: Int(endLine),
                                column: Int(endColumn),
                                utf8Offset: Int(endOffset)
                            )
                        ),
                        replacementText: replacement.map(String.init(cString:)) ?? "",
                        diagnosticText: diagnosticText.map(String.init(cString:)) ?? "",
                        diagnosticSeverity: mapDiagnosticSeverity(severity),
                        diagnosticIndex: Int(diagnosticIndex),
                        fixItIndex: Int(fixItIndex)
                    )
                )
            },
            Unmanaged.passUnretained(box).toOpaque(),
            &errorPointer
        )
        defer {
            if let errorPointer {
                sd_free_diagnostic_error(errorPointer)
            }
        }
        guard result == 0 else {
            let message = errorPointer.map { String(cString: $0) }
                ?? "libclang returned status \(result)"
            throw RepairError.evidenceUnavailable(message)
        }
        return box.values.sorted(by: StructuredDiagnosticFixIt.deterministicOrder)
    }
}

private final class FixItBox: @unchecked Sendable {
    var values: [StructuredDiagnosticFixIt] = []
}

private func mapDiagnosticSeverity(_ value: UInt32) -> Severity {
    switch value {
    case 3, 4: .error
    case 2: .warning
    default: .notice
    }
}

private extension StructuredDiagnosticFixIt {
    static func deterministicOrder(
        _ lhs: StructuredDiagnosticFixIt,
        _ rhs: StructuredDiagnosticFixIt
    ) -> Bool {
        (
            lhs.filePath,
            lhs.sourceRange.start.utf8Offset,
            lhs.sourceRange.end.utf8Offset,
            lhs.replacementText,
            lhs.diagnosticIndex,
            lhs.fixItIndex
        ) < (
            rhs.filePath,
            rhs.sourceRange.start.utf8Offset,
            rhs.sourceRange.end.utf8Offset,
            rhs.replacementText,
            rhs.diagnosticIndex,
            rhs.fixItIndex
        )
    }
}
