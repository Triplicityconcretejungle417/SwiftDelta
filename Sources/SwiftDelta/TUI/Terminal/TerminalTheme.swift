//===--- TerminalTheme.swift - SwiftDelta ------------------------------------------===//
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

enum TerminalBasicColor: Int, Codable, Sendable {
    case black = 0
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case magenta = 5
    case cyan = 6
    case white = 7
}

enum TerminalColor: Equatable, Sendable {
    case `default`
    case rgb(UInt8, UInt8, UInt8)
    case indexed(UInt8)
    case basic(TerminalBasicColor, bright: Bool)
}

struct TerminalStyle: Equatable, Sendable {
    var foreground: TerminalColor?
    var background: TerminalColor?
    var bold = false
    var dim = false
    var underline = false
    var reverse = false

    static let plain = TerminalStyle()
}

struct TerminalTheme: Sendable {
    // Default foreground and background preserve the user's terminal theme.
    let background: TerminalColor
    let surface: TerminalColor
    let elevated: TerminalColor
    let text: TerminalColor
    let secondary = TerminalColor.basic(.black, bright: true)
    let accent = TerminalColor.rgb(142, 104, 181)
    let selectionBackground = TerminalColor.rgb(255, 255, 255)
    let selectionForeground = TerminalColor.rgb(0, 0, 0)
    let mint = TerminalColor.basic(.green, bright: false)
    let warning = TerminalColor.basic(.yellow, bright: false)
    let error = TerminalColor.basic(.red, bright: false)

    init(
        background: TerminalColor = .default,
        text: TerminalColor = .default
    ) {
        self.background = background
        surface = background
        elevated = background
        self.text = text
    }

    func style(_ role: TerminalStyleRole, highContrast: Bool) -> TerminalStyle {
        let foreground: TerminalColor
        let backgroundColor: TerminalColor?
        var bold = false
        var dim = false
        let underline = false
        let reverse = false
        switch role {
        case .normal:
            foreground = text
            backgroundColor = background
        case .secondary:
            foreground = text
            backgroundColor = background
            dim = !highContrast
        case .header:
            foreground = text
            backgroundColor = background
            bold = true
        case .accent:
            foreground = highContrast ? text : accent
            backgroundColor = background
            bold = true
        case .primaryAction:
            foreground = highContrast ? text : accent
            backgroundColor = background
            bold = true
        case .destructive:
            foreground = highContrast ? text : error
            backgroundColor = background
            bold = true
        case .disabled:
            foreground = text
            backgroundColor = background
            dim = !highContrast
        case .success:
            foreground = highContrast ? text : mint
            backgroundColor = background
            bold = true
        case .warning:
            foreground = highContrast ? text : warning
            backgroundColor = background
            bold = true
        case .error:
            foreground = highContrast ? text : error
            backgroundColor = background
            bold = true
        case .diffAdded:
            foreground = highContrast ? text : mint
            backgroundColor = surface
        case .diffRemoved:
            foreground = highContrast ? text : error
            backgroundColor = surface
        case .diffContext:
            foreground = text
            backgroundColor = surface
            dim = !highContrast
        }
        return TerminalStyle(
            foreground: foreground,
            background: backgroundColor,
            bold: bold,
            dim: dim,
            underline: underline,
            reverse: reverse
        )
    }

    func selectionStyle(
        _ role: TerminalSelectionRole,
        capabilities: TerminalCapabilities
    ) -> TerminalStyle {
        let colors: (
            foreground: TerminalColor,
            background: TerminalColor
        ) = switch capabilities.colorMode {
        case .trueColor:
            (selectionForeground, selectionBackground)
        case .indexed256:
            (.indexed(16), .indexed(231))
        case .basic, .monochrome:
            (
                .basic(.black, bright: false),
                .basic(.white, bright: true)
            )
        }
        return TerminalStyle(
            foreground: colors.foreground,
            background: colors.background,
            bold: role != .disabled,
            dim: false,
            underline: false,
            reverse: false
        )
    }

    func sequence(
        for style: TerminalStyle,
        capabilities: TerminalCapabilities
    ) -> String {
        guard capabilities.colorMode != .monochrome else {
            if style.foreground == .basic(.black, bright: false),
               style.background == .basic(.white, bright: true)
            {
                var codes = ["0"]
                if style.bold { codes.append("1") }
                codes.append(contentsOf: ["30", "107"])
                return "\u{1B}[\(codes.joined(separator: ";"))m"
            }
            var codes: [String] = []
            if style.bold { codes.append("1") }
            if style.dim { codes.append("2") }
            if style.underline { codes.append("4") }
            if style.reverse { codes.append("7") }
            return codes.isEmpty ? "" : "\u{1B}[\(codes.joined(separator: ";"))m"
        }
        var codes: [String] = ["0"]
        if style.bold { codes.append("1") }
        if style.dim { codes.append("2") }
        if style.underline { codes.append("4") }
        if style.reverse { codes.append("7") }
        if let foreground = style.foreground {
            codes.append(contentsOf: colorCodes(
                foreground,
                foreground: true,
                mode: capabilities.colorMode
            ))
        }
        if let background = style.background {
            codes.append(contentsOf: colorCodes(
                background,
                foreground: false,
                mode: capabilities.colorMode
            ))
        }
        return "\u{1B}[\(codes.joined(separator: ";"))m"
    }

    private func colorCodes(
        _ color: TerminalColor,
        foreground: Bool,
        mode: TerminalColorMode
    ) -> [String] {
        let prefix = foreground ? "38" : "48"
        switch (color, mode) {
        case (.default, _):
            return [foreground ? "39" : "49"]
        case let (.rgb(red, green, blue), .trueColor):
            return [prefix, "2", "\(red)", "\(green)", "\(blue)"]
        case let (.rgb(red, green, blue), .indexed256):
            let index = indexedColor(red: red, green: green, blue: blue)
            return [prefix, "5", "\(index)"]
        case let (.indexed(index), .trueColor),
             let (.indexed(index), .indexed256):
            return [prefix, "5", "\(index)"]
        case let (.basic(color, bright), _):
            let base = foreground ? (bright ? 90 : 30) : (bright ? 100 : 40)
            return ["\(base + color.rawValue)"]
        case let (.rgb(red, green, blue), .basic):
            let basic = nearestBasic(red: red, green: green, blue: blue)
            let base = foreground ? 30 : 40
            return ["\(base + basic.rawValue)"]
        case let (.indexed(index), .basic):
            let base = foreground ? 30 : 40
            return ["\(base + Int(index % 8))"]
        case (_, .monochrome):
            return []
        }
    }

    private func indexedColor(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        let r = Int(red) * 5 / 255
        let g = Int(green) * 5 / 255
        let b = Int(blue) * 5 / 255
        return 16 + (36 * r) + (6 * g) + b
    }

    private func nearestBasic(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> TerminalBasicColor {
        let r = Int(red)
        let g = Int(green)
        let b = Int(blue)
        if max(r, g, b) < 72 { return .black }
        if min(r, g, b) > 190 { return .white }
        if r > g * 3 / 2, r > b * 3 / 2 { return .red }
        if g > r * 3 / 2, g > b * 3 / 2 { return .green }
        if b > r * 3 / 2, b > g * 3 / 2 { return .blue }
        if r > b, g > b { return .yellow }
        if r > g, b > g { return .magenta }
        return .cyan
    }
}

enum TerminalStyleRole: Sendable {
    case normal
    case secondary
    case header
    case accent
    case primaryAction
    case destructive
    case disabled
    case success
    case warning
    case error
    case diffAdded
    case diffRemoved
    case diffContext
}

enum TerminalSelectionRole: Equatable, Sendable {
    case normal
    case primary
    case warning
    case destructive
    case disabled
}

enum TerminalControl {
    static let reset = "\u{1B}[0m"
    static let enterAlternateScreen = "\u{1B}[?1049h"
    static let leaveAlternateScreen = "\u{1B}[?1049l"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let enableMouse = "\u{1B}[?1000h\u{1B}[?1006h"
    static let disableMouse = "\u{1B}[?1006l\u{1B}[?1000l"
    static let clearScreen = "\u{1B}[2J"
    static let clearLine = "\u{1B}[2K"

    static func move(row: Int, column: Int) -> String {
        "\u{1B}[\(max(1, row));\(max(1, column))H"
    }
}
