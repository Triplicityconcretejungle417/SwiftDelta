//===--- PackageManifestVisitor.swift - SwiftDelta ------------------------------------------===//
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
import SwiftSyntax

final class PackageManifestVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var platforms: [String: String] = [:]
    var platformLocations: [String: SourceLocation] = [:]
    var binaryTargets: [String] = []
    var pluginCount = 0

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        let callName = member.declName.baseName.text
        if let platform = normalizedPlatform(callName),
           let argument = node.arguments.first,
           let version = platformVersion(argument.expression)
        {
            platforms[platform] = version
            let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            platformLocations[platform] = SourceLocation(
                path: location.file,
                line: location.line,
                column: location.column
            )
        } else if callName == "binaryTarget" {
            if let pathArgument = node.arguments.first(where: {
                $0.label?.text == "path" || $0.label?.text == "url"
            }), let value = stringLiteralValue(pathArgument.expression) {
                binaryTargets.append(value)
            }
        } else if callName == "plugin" {
            pluginCount += 1
        }
        return .visitChildren
    }

    private func normalizedPlatform(_ name: String) -> String? {
        switch name {
        case "iOS": "iOS"
        case "macOS": "macOS"
        case "watchOS": "watchOS"
        case "tvOS": "tvOS"
        case "visionOS": "visionOS"
        default: nil
        }
    }

    private func platformVersion(_ expression: ExprSyntax) -> String? {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let value = member.declName.baseName.text
            guard value.hasPrefix("v") else {
                return nil
            }
            return String(value.dropFirst()).replacingOccurrences(of: "_", with: ".")
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let argument = call.arguments.first
        {
            return stringLiteralValue(argument.expression)
        }
        return stringLiteralValue(expression)
    }

    private func stringLiteralValue(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            return nil
        }
        return segment.content.text
    }
}
