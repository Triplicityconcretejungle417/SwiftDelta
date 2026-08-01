//===--- TerminalSymbols.swift - SwiftDelta ------------------------------------------===//
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

struct TerminalSymbols: Sendable {
    private let usesASCII: Bool

    init(capabilities: TerminalCapabilities) {
        usesASCII = capabilities.symbolMode == .ascii
    }

    var success: String { usesASCII ? "OK" : "✓" }
    var warning: String { usesASCII ? "!" : "▲" }
    var error: String { usesASCII ? "X" : "✕" }
    var notice: String { usesASCII ? "i" : "•" }
    var incomplete: String { usesASCII ? "~" : "◐" }
    var file: String { usesASCII ? "FILE" : "▱" }
    var sdk: String { usesASCII ? "SDK" : "◇" }
    var compiler: String { usesASCII ? "CC" : "⌁" }
    var safeRepair: String { usesASCII ? "+" : "✓" }
    var reviewRepair: String { usesASCII ? "?" : "◌" }
    var conflict: String { usesASCII ? "!" : "⊗" }
    var disclosure: String { usesASCII ? ">" : "›" }
}
