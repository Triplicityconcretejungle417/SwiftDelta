//===--- TerminalInput.swift - SwiftDelta ------------------------------------------===//
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

enum TUIKey: Equatable, Sendable {
    case character(Character)
    case enter
    case escape
    case tab
    case backTab
    case backspace
    case delete
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case interrupt
    case terminate
    case mouse(TUIMouseEvent)
}

struct TUIMouseEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case press
        case release
        case scrollUp
        case scrollDown
    }

    let kind: Kind
    let button: Int
    let column: Int
    let row: Int
}

struct TerminalInputDecoder: Sendable {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> [TUIKey] {
        buffer.append(contentsOf: bytes)
        var result: [TUIKey] = []
        while let key = decodeNext() {
            result.append(key)
        }
        return result
    }

    var hasPendingEscape: Bool {
        buffer == [0x1B]
    }

    mutating func flushPendingEscape() -> TUIKey? {
        // A short delay keeps split arrow and mouse sequences intact.
        guard hasPendingEscape else { return nil }
        buffer.removeFirst()
        return .escape
    }

    private mutating func decodeNext() -> TUIKey? {
        guard let first = buffer.first else { return nil }
        switch first {
        case 0x03:
            buffer.removeFirst()
            return .interrupt
        case 0x0D, 0x0A:
            buffer.removeFirst()
            return .enter
        case 0x09:
            buffer.removeFirst()
            return .tab
        case 0x7F, 0x08:
            buffer.removeFirst()
            return .backspace
        case 0x1B:
            return decodeEscapeSequence()
        default:
            return decodeCharacter()
        }
    }

    private mutating func decodeEscapeSequence() -> TUIKey? {
        guard buffer.count > 1 else {
            return nil
        }
        guard buffer[1] == 0x5B else {
            buffer.removeFirst()
            return .escape
        }
        guard buffer.count > 2 else { return nil }
        switch buffer[2] {
        case 0x41:
            buffer.removeFirst(3)
            return .up
        case 0x42:
            buffer.removeFirst(3)
            return .down
        case 0x43:
            buffer.removeFirst(3)
            return .right
        case 0x44:
            buffer.removeFirst(3)
            return .left
        case 0x48:
            buffer.removeFirst(3)
            return .home
        case 0x46:
            buffer.removeFirst(3)
            return .end
        case 0x5A:
            buffer.removeFirst(3)
            return .backTab
        case 0x3C:
            return decodeMouse()
        default:
            return decodeTildeSequence()
        }
    }

    private mutating func decodeTildeSequence() -> TUIKey? {
        guard let tilde = buffer.firstIndex(of: 0x7E) else {
            if buffer.count > 12 {
                buffer.removeFirst()
                return .escape
            }
            return nil
        }
        let code = String(
            bytes: buffer[2..<tilde],
            encoding: .ascii
        ) ?? ""
        buffer.removeFirst(tilde + 1)
        switch code {
        case "1", "7": return .home
        case "3": return .delete
        case "4", "8": return .end
        case "5": return .pageUp
        case "6": return .pageDown
        default: return .escape
        }
    }

    private mutating func decodeMouse() -> TUIKey? {
        guard let terminator = buffer.firstIndex(where: {
            $0 == 0x4D || $0 == 0x6D
        }) else {
            return nil
        }
        let payload = String(
            bytes: buffer[3..<terminator],
            encoding: .ascii
        ) ?? ""
        let values = payload.split(separator: ";").compactMap {
            Int($0)
        }
        let released = buffer[terminator] == 0x6D
        buffer.removeFirst(terminator + 1)
        guard values.count == 3 else { return .escape }
        let button = values[0]
        let kind: TUIMouseEvent.Kind
        if button & 64 != 0 {
            kind = button & 1 == 0 ? .scrollUp : .scrollDown
        } else {
            kind = released ? .release : .press
        }
        return .mouse(
            TUIMouseEvent(
                kind: kind,
                button: button & 3,
                column: max(0, values[1] - 1),
                row: max(0, values[2] - 1)
            )
        )
    }

    private mutating func decodeCharacter() -> TUIKey? {
        guard let first = buffer.first else { return nil }
        let count: Int
        switch first {
        case 0x00...0x7F: count = 1
        case 0xC2...0xDF: count = 2
        case 0xE0...0xEF: count = 3
        case 0xF0...0xF4: count = 4
        default:
            buffer.removeFirst()
            return .character("�")
        }
        guard buffer.count >= count else { return nil }
        let bytes = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        guard let value = String(bytes: bytes, encoding: .utf8),
              let character = value.first
        else {
            return .character("�")
        }
        return .character(character)
    }
}
