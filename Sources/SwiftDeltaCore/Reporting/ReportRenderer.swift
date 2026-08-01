//===--- ReportRenderer.swift - SwiftDelta ------------------------------------------===//
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

/// Dispatches report encoding without changing the format-specific schemas.
public enum ReportRenderer {
    public static func render(
        _ report: AnalysisReport,
        format: ReportFormat,
        failureLevel: Severity = .error
    ) throws -> Data {
        switch format {
        case .terminal:
            Data(
                TerminalReportRenderer.render(
                    report,
                    failureLevel: failureLevel
                ).utf8
            )
        case .json:
            try JSONReportRenderer.render(report)
        case .sarif:
            try SARIFReportRenderer.render(report)
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw SwiftDeltaError.outputWrite(path: url.path, reason: error.localizedDescription)
        }
    }
}
