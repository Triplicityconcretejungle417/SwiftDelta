//===--- TerminalCapabilities.swift - SwiftDelta ------------------------------------------===//
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

enum TerminalColorMode: String, Codable, CaseIterable, Sendable {
    case trueColor
    case indexed256
    case basic
    case monochrome
}

enum TerminalSymbolMode: String, Codable, CaseIterable, Sendable {
    case unicode
    case ascii
}

struct TerminalCapabilities: Equatable, Sendable {
    var colorMode: TerminalColorMode
    var symbolMode: TerminalSymbolMode
    var highContrast: Bool
    var reducedMotion: Bool
    var mouseSupported: Bool

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalCapabilities {
        let term = environment["TERM"]?.lowercased() ?? ""
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        let noColor = environment["NO_COLOR"] != nil
        let dumb = term.isEmpty || term == "dumb"
        let colorMode: TerminalColorMode
        if noColor || dumb {
            colorMode = .monochrome
        } else if colorTerm.contains("truecolor") || colorTerm.contains("24bit") {
            colorMode = .trueColor
        } else if term.contains("256color") {
            colorMode = .indexed256
        } else {
            colorMode = .basic
        }
        let locale = [
            environment["LC_ALL"],
            environment["LC_CTYPE"],
            environment["LANG"],
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        let ascii = dumb || locale == "c" || locale.hasPrefix("c.")
        return TerminalCapabilities(
            colorMode: colorMode,
            symbolMode: ascii ? .ascii : .unicode,
            highContrast: false,
            reducedMotion: false,
            mouseSupported: !dumb
        )
    }
}

struct TerminalSize: Equatable, Sendable {
    var columns: Int
    var rows: Int

    static let minimum = TerminalSize(columns: 64, rows: 18)

    var isUsable: Bool {
        columns >= Self.minimum.columns && rows >= Self.minimum.rows
    }
}
