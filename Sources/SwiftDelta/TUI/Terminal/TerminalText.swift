//===--- TerminalText.swift - SwiftDelta ------------------------------------------===//
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

enum TerminalText {
    static func sanitize(
        _ value: String,
        preservingNewlines: Bool = false
    ) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar == "\n", preservingNewlines {
                result.append(scalar)
                continue
            }
            if scalar.value < 0x20 || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
            {
                result.append(" ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    static func displayWidth(_ value: String) -> Int {
        value.reduce(into: 0) { width, character in
            width += characterWidth(character)
        }
    }

    static func clipped(_ value: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let clean = sanitize(value)
        var result = ""
        var used = 0
        for character in clean {
            let next = characterWidth(character)
            if used + next > width { break }
            result.append(character)
            used += next
        }
        return result
    }

    static func truncated(_ value: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let clean = sanitize(value)
        guard displayWidth(clean) > width else { return clean }
        guard width > 1 else { return "…" }
        return clipped(clean, width: width - 1) + "…"
    }

    static func padded(_ value: String, width: Int) -> String {
        let clippedValue = clipped(value, width: width)
        let padding = max(0, width - displayWidth(clippedValue))
        return clippedValue + String(repeating: " ", count: padding)
    }

    static func droppingColumns(_ value: String, count: Int) -> String {
        guard count > 0 else { return sanitize(value) }
        let clean = sanitize(value)
        var removed = 0
        var result = ""
        for character in clean {
            let width = characterWidth(character)
            if removed < count {
                removed += width
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func characterWidth(_ character: Character) -> Int {
        guard let first = character.unicodeScalars.first else { return 0 }
        if first.properties.generalCategory == .nonspacingMark
            || first.properties.generalCategory == .enclosingMark
        {
            return 0
        }
        let value = first.value
        let wide =
            (0x1100...0x115F).contains(value)
            || (0x2329...0x232A).contains(value)
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
            || (0x20000...0x3FFFD).contains(value)
        return wide ? 2 : 1
    }
}
