//===--- ExitStatusEvaluator.swift - SwiftDelta ------------------------------------------===//
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

public enum ExitStatusEvaluator {
    public static func status(
        for findings: [Finding],
        failureLevel: Severity
    ) -> Int32 {
        findings.contains { $0.severity.isAtLeast(failureLevel) } ? 1 : 0
    }

    public static func status(
        for report: AnalysisReport,
        failureLevel: Severity,
        allowIncomplete: Bool = false
    ) -> Int32 {
        if !allowIncomplete,
           report.analysisState == .incomplete
            || report.analysisState == .blocked
        {
            return 2
        }
        return status(for: report.findings, failureLevel: failureLevel)
    }
}
