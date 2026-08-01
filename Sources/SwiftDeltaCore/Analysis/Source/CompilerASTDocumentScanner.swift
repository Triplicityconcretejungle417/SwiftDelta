//===--- CompilerASTDocumentScanner.swift - SwiftDelta ------------------------------------------===//
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

struct CompilerASTScannedDocument {
    let kind: String?
    let filename: String?
    let importedModules: [String]
    let references: [CompilerASTScannedReference]
}

struct CompilerASTScannedReference {
    let byteOffset: Int
    let stableIdentities: [String]
    let type: String?
    let hasDeclaration: Bool
    let declarationUSRWasEmpty: Bool
}

/// Reads the compiler's deeply nested AST JSON without materializing its full
/// object graph. Some valid Swift expressions exceed Foundation's JSON nesting
/// limit, while the evidence needed here is limited to a small set of fields.
enum CompilerASTDocumentScanner {
    static func scan(_ data: Data) throws -> CompilerASTScannedDocument {
        var parser = Parser(data: data)
        return try parser.parse()
    }
}

private extension CompilerASTDocumentScanner {
    enum ParseError: Error {
        case malformed
    }

    enum Token {
        case objectStart
        case objectEnd
        case arrayStart
        case arrayEnd
        case colon
        case comma
        case string(String)
        case number(Int?)
        case boolean(Bool)
        case null
    }

    enum ObjectState {
        case keyOrEnd
        case colon
        case value
        case commaOrEnd
    }

    enum ArrayState {
        case valueOrEnd
        case commaOrEnd
    }

    final class ObjectFrame {
        let attachmentKey: String?
        let sequence: Int
        var state = ObjectState.keyOrEnd
        var key: String?
        var kind: String?
        var filename: String?
        var implicit = false
        var type: String?
        var directUSR: String?
        var hasDirectUSR = false
        var hasDeclaration = false
        var declarationUSR: String?
        var declarationUSRWasEmpty = false
        var hasOverloadSet = false
        var overloadUSRs: [String] = []
        var rangeStart: Int?
        var numericStart: Int?
        var modulePath: String?

        init(attachmentKey: String?, sequence: Int) {
            self.attachmentKey = attachmentKey
            self.sequence = sequence
        }
    }

    final class ArrayFrame {
        let attachmentKey: String?
        var state = ArrayState.valueOrEnd
        var firstString: String?
        var directUSRs: [String] = []

        init(attachmentKey: String?) {
            self.attachmentKey = attachmentKey
        }
    }

    enum Frame {
        case object(ObjectFrame)
        case array(ArrayFrame)
    }

    struct SequencedReference {
        let sequence: Int
        let value: CompilerASTScannedReference
    }

    struct Parser {
        private let bytes: [UInt8]
        private var index = 0
        private var frames: [Frame] = []
        private var nextSequence = 0
        private var rootKind: String?
        private var rootFilename: String?
        private var importedModules = Set<String>()
        private var references: [SequencedReference] = []
        private var completedRoot = false

        init(data: Data) {
            bytes = Array(data)
        }

        mutating func parse() throws -> CompilerASTScannedDocument {
            while let token = try nextToken() {
                if completedRoot {
                    throw ParseError.malformed
                }
                try consume(token)
            }
            guard completedRoot, frames.isEmpty else {
                throw ParseError.malformed
            }
            return CompilerASTScannedDocument(
                kind: rootKind,
                filename: rootFilename,
                importedModules: importedModules.sorted(),
                references: references
                    .sorted { $0.sequence < $1.sequence }
                    .map(\.value)
            )
        }

        private mutating func consume(_ token: Token) throws {
            switch token {
            case .objectStart:
                let attachment = try beginContainerValue()
                let frame = ObjectFrame(
                    attachmentKey: attachment,
                    sequence: nextSequence
                )
                nextSequence += 1
                frames.append(.object(frame))
            case .arrayStart:
                frames.append(
                    .array(
                        ArrayFrame(
                            attachmentKey: try beginContainerValue()
                        )
                    )
                )
            case .objectEnd:
                try endObject()
            case .arrayEnd:
                try endArray()
            case .colon:
                guard case let .object(frame)? = frames.last,
                      frame.state == .colon
                else {
                    throw ParseError.malformed
                }
                frame.state = .value
            case .comma:
                try consumeComma()
            case let .string(value):
                try consumeString(value)
            case let .number(value):
                try consumePrimitive(.number(value))
            case let .boolean(value):
                try consumePrimitive(.boolean(value))
            case .null:
                try consumePrimitive(.null)
            }
        }

        private mutating func beginContainerValue() throws -> String? {
            guard let parent = frames.last else {
                guard !completedRoot else {
                    throw ParseError.malformed
                }
                return nil
            }
            switch parent {
            case let .object(frame):
                guard frame.state == .value, let key = frame.key else {
                    throw ParseError.malformed
                }
                frame.key = nil
                frame.state = .commaOrEnd
                return key
            case let .array(frame):
                guard frame.state == .valueOrEnd else {
                    throw ParseError.malformed
                }
                frame.state = .commaOrEnd
                return frame.attachmentKey
            }
        }

        private mutating func endObject() throws {
            guard case let .object(frame)? = frames.last,
                  frame.state == .keyOrEnd || frame.state == .commaOrEnd
            else {
                throw ParseError.malformed
            }
            frames.removeLast()
            record(frame)
            if let parent = frames.last {
                attach(frame, to: parent)
            } else {
                rootKind = frame.kind
                rootFilename = frame.filename
                completedRoot = true
            }
        }

        private mutating func endArray() throws {
            guard case let .array(frame)? = frames.last,
                  frame.state == .valueOrEnd || frame.state == .commaOrEnd
            else {
                throw ParseError.malformed
            }
            frames.removeLast()
            if case let .object(parent)? = frames.last {
                switch frame.attachmentKey {
                case "module_path":
                    parent.modulePath = frame.firstString
                case "decls":
                    parent.hasOverloadSet = true
                    parent.overloadUSRs.append(contentsOf: frame.directUSRs)
                default:
                    break
                }
            } else if frames.isEmpty {
                throw ParseError.malformed
            }
        }

        private func attach(_ child: ObjectFrame, to parent: Frame) {
            switch parent {
            case let .object(frame):
                switch child.attachmentKey {
                case "decl":
                    frame.hasDeclaration = true
                    frame.declarationUSR = child.directUSR
                    frame.declarationUSRWasEmpty =
                        child.hasDirectUSR && child.directUSR?.isEmpty == true
                case "range":
                    frame.rangeStart = child.numericStart
                default:
                    break
                }
            case let .array(frame):
                if frame.attachmentKey == "decls",
                   let usr = child.directUSR,
                   !usr.isEmpty
                {
                    frame.directUSRs.append(usr)
                }
            }
        }

        private mutating func record(_ frame: ObjectFrame) {
            if frame.kind == "import_decl", let module = frame.modulePath {
                importedModules.insert(module)
            }
            guard frame.implicit == false,
                  let kind = frame.kind,
                  isReferenceExpression(
                      kind: kind,
                      hasDeclaration: frame.hasDeclaration,
                      hasDirectUSR: frame.hasDirectUSR,
                      hasOverloadSet: frame.hasOverloadSet
                  )
            else {
                return
            }
            var identities = frame.overloadUSRs
            if let usr = frame.directUSR, !usr.isEmpty {
                identities.append(usr)
            }
            if let usr = frame.declarationUSR, !usr.isEmpty {
                identities.append(usr)
            }
            references.append(
                SequencedReference(
                    sequence: frame.sequence,
                    value: CompilerASTScannedReference(
                        byteOffset: frame.rangeStart ?? 0,
                        stableIdentities: Array(Set(identities)).sorted(),
                        type: frame.type,
                        hasDeclaration: frame.hasDeclaration,
                        declarationUSRWasEmpty:
                            frame.declarationUSRWasEmpty
                    )
                )
            )
        }

        private func isReferenceExpression(
            kind: String,
            hasDeclaration: Bool,
            hasDirectUSR: Bool,
            hasOverloadSet: Bool
        ) -> Bool {
            guard kind.hasSuffix("_expr") else {
                return false
            }
            let referenceKinds: Set<String> = [
                "declref_expr",
                "member_ref_expr",
                "overloaded_decl_ref_expr",
                "other_constructor_decl_ref_expr",
                "type_expr",
            ]
            return referenceKinds.contains(kind)
                || hasDeclaration
                || hasDirectUSR
                || hasOverloadSet
        }

        private mutating func consumeComma() throws {
            guard let frame = frames.last else {
                throw ParseError.malformed
            }
            switch frame {
            case let .object(object):
                guard object.state == .commaOrEnd else {
                    throw ParseError.malformed
                }
                object.state = .keyOrEnd
            case let .array(array):
                guard array.state == .commaOrEnd else {
                    throw ParseError.malformed
                }
                array.state = .valueOrEnd
            }
        }

        private mutating func consumeString(_ value: String) throws {
            guard let frame = frames.last else {
                throw ParseError.malformed
            }
            switch frame {
            case let .object(object):
                if object.state == .keyOrEnd {
                    object.key = value
                    object.state = .colon
                    return
                }
                guard object.state == .value, let key = object.key else {
                    throw ParseError.malformed
                }
                apply(.string(value), key: key, to: object)
                object.key = nil
                object.state = .commaOrEnd
            case let .array(array):
                guard array.state == .valueOrEnd else {
                    throw ParseError.malformed
                }
                if array.firstString == nil {
                    array.firstString = value
                }
                array.state = .commaOrEnd
            }
        }

        private mutating func consumePrimitive(_ token: Token) throws {
            guard let frame = frames.last else {
                throw ParseError.malformed
            }
            switch frame {
            case let .object(object):
                guard object.state == .value, let key = object.key else {
                    throw ParseError.malformed
                }
                apply(token, key: key, to: object)
                object.key = nil
                object.state = .commaOrEnd
            case let .array(array):
                guard array.state == .valueOrEnd else {
                    throw ParseError.malformed
                }
                array.state = .commaOrEnd
            }
        }

        private func apply(
            _ token: Token,
            key: String,
            to frame: ObjectFrame
        ) {
            switch (key, token) {
            case let ("_kind", .string(value)):
                frame.kind = value
            case let ("filename", .string(value)):
                frame.filename = value
            case let ("implicit", .boolean(value)):
                frame.implicit = value
            case let ("type", .string(value)):
                frame.type = value
            case let ("decl_usr", .string(value)):
                frame.hasDirectUSR = true
                frame.directUSR = value
            case let ("start", .number(value)):
                frame.numericStart = value
            default:
                break
            }
        }

        private mutating func nextToken() throws -> Token? {
            skipWhitespace()
            guard index < bytes.count else {
                return nil
            }
            switch bytes[index] {
            case 0x7B:
                index += 1
                return .objectStart
            case 0x7D:
                index += 1
                return .objectEnd
            case 0x5B:
                index += 1
                return .arrayStart
            case 0x5D:
                index += 1
                return .arrayEnd
            case 0x3A:
                index += 1
                return .colon
            case 0x2C:
                index += 1
                return .comma
            case 0x22:
                return .string(try parseString())
            case 0x74:
                try consumeLiteral("true")
                return .boolean(true)
            case 0x66:
                try consumeLiteral("false")
                return .boolean(false)
            case 0x6E:
                try consumeLiteral("null")
                return .null
            case 0x2D, 0x30...0x39:
                return .number(parseNumber())
            default:
                throw ParseError.malformed
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20
                    || bytes[index] == 0x09
                    || bytes[index] == 0x0A
                    || bytes[index] == 0x0D
            {
                index += 1
            }
        }

        private mutating func consumeLiteral(_ literal: StaticString) throws {
            let value = Array(String(describing: literal).utf8)
            guard index + value.count <= bytes.count,
                  Array(bytes[index..<(index + value.count)]) == value
            else {
                throw ParseError.malformed
            }
            index += value.count
        }

        private mutating func parseNumber() -> Int? {
            let start = index
            while index < bytes.count,
                  bytes[index] == 0x2D
                    || bytes[index] == 0x2B
                    || bytes[index] == 0x2E
                    || bytes[index] == 0x45
                    || bytes[index] == 0x65
                    || (0x30...0x39).contains(bytes[index])
            {
                index += 1
            }
            return Int(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func parseString() throws -> String {
            guard bytes[index] == 0x22 else {
                throw ParseError.malformed
            }
            index += 1
            var output: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    guard let value = String(bytes: output, encoding: .utf8) else {
                        throw ParseError.malformed
                    }
                    return value
                }
                guard byte != 0x5C else {
                    try appendEscape(to: &output)
                    continue
                }
                guard byte >= 0x20 else {
                    throw ParseError.malformed
                }
                output.append(byte)
            }
            throw ParseError.malformed
        }

        private mutating func appendEscape(to output: inout [UInt8]) throws {
            guard index < bytes.count else {
                throw ParseError.malformed
            }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case 0x22, 0x5C, 0x2F:
                output.append(escaped)
            case 0x62:
                output.append(0x08)
            case 0x66:
                output.append(0x0C)
            case 0x6E:
                output.append(0x0A)
            case 0x72:
                output.append(0x0D)
            case 0x74:
                output.append(0x09)
            case 0x75:
                let first = try parseUnicodeEscape()
                let scalar: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    guard index + 2 <= bytes.count,
                          bytes[index] == 0x5C,
                          bytes[index + 1] == 0x75
                    else {
                        throw ParseError.malformed
                    }
                    index += 2
                    let second = try parseUnicodeEscape()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw ParseError.malformed
                    }
                    scalar = 0x10000
                        + ((first - 0xD800) << 10)
                        + (second - 0xDC00)
                } else {
                    scalar = first
                }
                guard let unicode = UnicodeScalar(scalar) else {
                    throw ParseError.malformed
                }
                output.append(contentsOf: String(unicode).utf8)
            default:
                throw ParseError.malformed
            }
        }

        private mutating func parseUnicodeEscape() throws -> UInt32 {
            guard index + 4 <= bytes.count else {
                throw ParseError.malformed
            }
            var value: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                value <<= 4
                switch byte {
                case 0x30...0x39:
                    value += UInt32(byte - 0x30)
                case 0x41...0x46:
                    value += UInt32(byte - 0x41 + 10)
                case 0x61...0x66:
                    value += UInt32(byte - 0x61 + 10)
                default:
                    throw ParseError.malformed
                }
            }
            index += 4
            return value
        }
    }
}
