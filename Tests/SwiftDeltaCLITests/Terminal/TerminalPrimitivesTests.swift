//===--- TerminalPrimitivesTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDelta
import SwiftDeltaCore
import XCTest

final class TerminalPrimitivesTests: XCTestCase {
    func testCapabilityDetectionSupportsAllFallbackLevelsAndNoColor() {
        XCTAssertEqual(
            TerminalCapabilities.detect(environment: [
                "TERM": "xterm-256color", "COLORTERM": "truecolor",
                "LANG": "en_US.UTF-8",
            ]).colorMode,
            .trueColor
        )
        XCTAssertEqual(
            TerminalCapabilities.detect(environment: [
                "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            ]).colorMode,
            .indexed256
        )
        XCTAssertEqual(
            TerminalCapabilities.detect(environment: [
                "TERM": "vt100", "LANG": "en_US.UTF-8",
            ]).colorMode,
            .basic
        )
        XCTAssertEqual(
            TerminalCapabilities.detect(environment: [
                "TERM": "xterm-256color", "NO_COLOR": "",
            ]).colorMode,
            .monochrome
        )
        XCTAssertEqual(
            TerminalCapabilities.detect(environment: [
                "TERM": "dumb", "LANG": "C",
            ]).symbolMode,
            .ascii
        )
    }

    func testInputDecoderHandlesKeyboardUnicodeAndMouseSequences() {
        var decoder = TerminalInputDecoder()
        let bytes =
            Array("\u{1B}[A\u{1B}[B\u{1B}[Z".utf8)
            + Array("界".utf8)
            + Array("\u{1B}[<64;10;5M".utf8)

        XCTAssertEqual(
            decoder.append(bytes),
            [
                .up,
                .down,
                .backTab,
                .character("界"),
                .mouse(
                    TUIMouseEvent(
                        kind: .scrollUp,
                        button: 0,
                        column: 9,
                        row: 4
                    )
                ),
            ]
        )
        XCTAssertEqual(decoder.append([0x03]), [.interrupt])
    }

    func testInputDecoderRetainsIncompleteUTF8AcrossReads() {
        var decoder = TerminalInputDecoder()
        let bytes = Array("界".utf8)

        XCTAssertEqual(decoder.append(Array(bytes.prefix(2))), [])
        XCTAssertEqual(decoder.append(Array(bytes.suffix(1))), [.character("界")])
    }

    func testInputDecoderRetainsFragmentedEscapeSequencesAcrossReads() {
        var decoder = TerminalInputDecoder()

        XCTAssertEqual(decoder.append([0x1B]), [])
        XCTAssertTrue(decoder.hasPendingEscape)
        XCTAssertEqual(decoder.append(Array("[A".utf8)), [.up])

        XCTAssertEqual(decoder.append(Array("\u{1B}[5".utf8)), [])
        XCTAssertEqual(decoder.append(Array("~".utf8)), [.pageUp])

        XCTAssertEqual(decoder.append(Array("\u{1B}[".utf8)), [])
        XCTAssertEqual(decoder.append(Array("Z".utf8)), [.backTab])

        XCTAssertEqual(decoder.append(Array("\u{1B}[<64;10".utf8)), [])
        XCTAssertEqual(
            decoder.append(Array(";5M".utf8)),
            [
                .mouse(
                    TUIMouseEvent(
                        kind: .scrollUp,
                        button: 0,
                        column: 9,
                        row: 4
                    )
                ),
            ]
        )
        XCTAssertEqual(decoder.append([0x1B]), [])
        XCTAssertEqual(decoder.flushPendingEscape(), .escape)
    }

    func testSanitizerNeutralizesANSIAndOSCInjection() {
        let malicious =
            "name\u{1B}[31m red\u{1B}]52;c;clipboard\u{07}\u{1B}[2J"
        let sanitized = TerminalText.sanitize(malicious)

        XCTAssertFalse(sanitized.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertFalse(sanitized.unicodeScalars.contains { $0.value == 0x07 })
        XCTAssertTrue(sanitized.contains("clipboard"))
    }

    func testSanitizerPropertyCorpusNeverEmitsTerminalControls() {
        var generator = DeterministicGenerator(seed: 0x5A17_C0DE)
        for _ in 0..<500 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<128 {
                let choice = generator.next() % 5
                let value: UInt32
                switch choice {
                case 0:
                    value = UInt32(generator.next() % 0x20)
                case 1:
                    value = 0x7F + UInt32(generator.next() % 0x21)
                case 2:
                    value = 0x20 + UInt32(generator.next() % 0x5F)
                case 3:
                    value = 0x4E00 + UInt32(generator.next() % 128)
                default:
                    value = 0x1F600 + UInt32(generator.next() % 64)
                }
                if let scalar = UnicodeScalar(value) {
                    scalars.append(scalar)
                }
            }
            let sanitized = TerminalText.sanitize(String(scalars))
            XCTAssertFalse(
                sanitized.unicodeScalars.contains {
                    $0.value < 0x20 || $0.value == 0x7F
                        || (0x80...0x9F).contains($0.value)
                }
            )
            for width in [1, 7, 31, 80] {
                XCTAssertLessThanOrEqual(
                    TerminalText.displayWidth(
                        TerminalText.clipped(sanitized, width: width)
                    ),
                    width
                )
            }
        }
    }

    func testUnicodeWidthClippingAndLongTextStayWithinBounds() {
        XCTAssertEqual(TerminalText.displayWidth("A界B"), 4)
        XCTAssertEqual(TerminalText.clipped("A界B", width: 3), "A界")
        XCTAssertEqual(
            TerminalText.displayWidth(
                TerminalText.truncated(String(repeating: "x", count: 100), width: 8)
            ),
            8
        )
        var canvas = TerminalCanvas(size: TerminalSize(columns: 8, rows: 2))
        canvas.write(
            "A界B-long",
            row: 0,
            column: 5,
            style: .plain,
            maximumWidth: 3
        )
        XCTAssertEqual(canvas.rows[0].count, 8)
    }

    func testRenderingSupportsTrueColorIndexedMonochromeAndASCII() {
        let theme = TerminalTheme()
        var canvas = TerminalCanvas(size: TerminalSize(columns: 80, rows: 24))
        DeltaMark.drawWelcome(
            on: &canvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            )
        )
        let trueColor = canvas.encodedLines(
            theme: theme,
            capabilities: TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            )
        ).joined()
        let indexed = canvas.encodedLines(
            theme: theme,
            capabilities: TerminalCapabilities(
                colorMode: .indexed256,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            )
        ).joined()
        let mono = canvas.encodedLines(
            theme: theme,
            capabilities: TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: false
            )
        ).joined()

        XCTAssertTrue(trueColor.contains("█"))
        XCTAssertTrue(trueColor.contains("▀"))
        XCTAssertTrue(trueColor.contains("▄"))
        XCTAssertFalse(trueColor.contains("SwiftDelta"))
        XCTAssertTrue(trueColor.contains("38;2;"))
        XCTAssertFalse(trueColor.contains("48;2;"))
        XCTAssertTrue(indexed.contains("38;5;"))
        XCTAssertFalse(indexed.contains("48;5;"))
        XCTAssertFalse(mono.contains("[38;"))
        var asciiCanvas = TerminalCanvas(
            size: TerminalSize(columns: 80, rows: 24)
        )
        DeltaMark.drawWelcome(
            on: &asciiCanvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            )
        )
        let ascii = asciiCanvas.rows.flatMap { $0 }
            .filter { !$0.continuation }
            .map(\.text)
            .joined()
        XCTAssertTrue(ascii.contains("#"))
        XCTAssertFalse(ascii.contains("█"))
        XCTAssertFalse(ascii.contains("▀"))
        XCTAssertFalse(ascii.contains("▄"))
    }

    func testLargeBrandUsesLayeredSwiftBirdsShadowsAndReadableFallbacks() {
        let theme = TerminalTheme()
        let trueColor = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        XCTAssertEqual(DeltaMark.brandColor, .rgb(240, 81, 56))
        XCTAssertEqual(DeltaMark.candidateDepthColor, .rgb(216, 65, 44))
        XCTAssertEqual(
            DeltaMark.candidateHighlightColor,
            .rgb(255, 154, 132)
        )
        XCTAssertEqual(DeltaMark.baselineColor, .rgb(194, 70, 50))
        XCTAssertEqual(DeltaMark.baselineDepthColor, .rgb(145, 58, 43))
        XCTAssertEqual(DeltaMark.shadowColor, .rgb(104, 96, 93))
        XCTAssertEqual(
            DeltaMark.largeTerminalSize,
            TerminalSize(columns: 38, rows: 21)
        )
        XCTAssertEqual(
            DeltaMark.mediumTerminalSize,
            TerminalSize(columns: 26, rows: 15)
        )
        XCTAssertEqual(
            DeltaMark.compactTerminalSize,
            TerminalSize(columns: 68, rows: 5)
        )
        var canvas = TerminalCanvas(size: DeltaMark.largeTerminalSize)
        DeltaMark.drawLarge(
            on: &canvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: trueColor
        )

        let artwork = canvas.rows.flatMap { $0 }.map(\.text).joined()
        XCTAssertTrue(artwork.contains("█"))
        XCTAssertTrue(artwork.contains("▀"))
        XCTAssertTrue(artwork.contains("▄"))
        XCTAssertFalse(artwork.contains("SWIFTDELTA"))
        XCTAssertFalse(artwork.contains("SwiftDelta"))

        let coloredPixels = canvas.rows.flatMap { $0 }
            .filter { $0.text != " " }
        let brandColors: [TerminalColor] = [
            DeltaMark.brandColor,
            DeltaMark.candidateDepthColor,
            DeltaMark.candidateHighlightColor,
            DeltaMark.baselineColor,
            DeltaMark.baselineDepthColor,
            DeltaMark.shadowColor,
        ]
        XCTAssertTrue(coloredPixels.allSatisfy {
            guard let foreground = $0.style.foreground else { return false }
            return brandColors.contains(foreground)
        })
        XCTAssertTrue(coloredPixels.allSatisfy {
            $0.style.background == theme.background
        })
        for color in brandColors {
            XCTAssertTrue(coloredPixels.contains {
                $0.style.foreground == color
            })
        }
        XCTAssertTrue(
            canvas.rows[0][29].style.foreground.map {
                [
                    DeltaMark.brandColor,
                    DeltaMark.candidateDepthColor,
                    DeltaMark.candidateHighlightColor,
                ].contains($0)
            } ?? false
        )
        XCTAssertTrue(
            canvas.rows[1][11].style.foreground.map {
                [
                    DeltaMark.baselineColor,
                    DeltaMark.baselineDepthColor,
                ].contains($0)
            } ?? false
        )
        XCTAssertEqual(
            canvas.rows[1][37].style.foreground,
            DeltaMark.shadowColor
        )
        XCTAssertNotEqual(canvas.rows[0][30].text, " ")
        XCTAssertNotEqual(canvas.rows[1][23].text, " ")
        XCTAssertEqual(canvas.rows[0][0].text, " ")
        XCTAssertEqual(canvas.rows[10][0].text, " ")
        XCTAssertNotEqual(canvas.rows[12][9].text, " ")
        XCTAssertEqual(
            canvas.rows[12][9].style.foreground,
            DeltaMark.candidateHighlightColor
        )
        let wordmarkPixels = canvas.rows[12..<21].flatMap { $0 }
            .filter { $0.text != " " }
        for color in [
            DeltaMark.candidateHighlightColor,
            DeltaMark.brandColor,
            DeltaMark.candidateDepthColor,
            DeltaMark.shadowColor,
        ] {
            XCTAssertTrue(wordmarkPixels.contains {
                $0.style.foreground == color
            })
        }

        var mediumCanvas = TerminalCanvas(size: DeltaMark.mediumTerminalSize)
        DeltaMark.drawMediumBrand(
            on: &mediumCanvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: trueColor
        )
        var compactCanvas = TerminalCanvas(size: DeltaMark.compactTerminalSize)
        DeltaMark.drawCompactBrand(
            on: &compactCanvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: trueColor
        )
        let dimensionalTitleColors = [
            DeltaMark.candidateHighlightColor,
            DeltaMark.brandColor,
            DeltaMark.candidateDepthColor,
            DeltaMark.shadowColor,
        ]
        let mediumTitlePixels = mediumCanvas.rows[11..<15].flatMap { $0 }
            .filter { $0.text != " " }
        let compactTitlePixels = compactCanvas.rows.flatMap {
            $0.dropFirst(18)
        }.filter { $0.text != " " }
        for titlePixels in [mediumTitlePixels, compactTitlePixels] {
            for color in dimensionalTitleColors {
                XCTAssertTrue(titlePixels.contains {
                    $0.style.foreground == color
                })
            }
        }
        for variant in [mediumCanvas, compactCanvas] {
            let pixels = variant.rows.flatMap { $0 }
                .filter { $0.text != " " }
            XCTAssertFalse(pixels.isEmpty)
            XCTAssertTrue(pixels.allSatisfy {
                guard let foreground = $0.style.foreground else {
                    return false
                }
                return brandColors.contains(foreground)
                    && $0.style.background == theme.background
            })
            XCTAssertTrue(pixels.contains {
                $0.style.foreground == DeltaMark.baselineColor
            })
            XCTAssertTrue(pixels.contains {
                $0.style.foreground == DeltaMark.brandColor
            })
            XCTAssertTrue(pixels.contains {
                $0.style.foreground == DeltaMark.shadowColor
            })
        }

        let highContrast = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .unicode,
            highContrast: true,
            reducedMotion: true,
            mouseSupported: false
        )
        var highContrastCanvas = TerminalCanvas(
            size: DeltaMark.largeTerminalSize
        )
        DeltaMark.drawLarge(
            on: &highContrastCanvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: highContrast
        )
        let highContrastPixels = highContrastCanvas.rows.flatMap { $0 }
            .filter { $0.text != " " }
        XCTAssertTrue(highContrastPixels.allSatisfy {
            $0.style.foreground == theme.text
        })
        XCTAssertTrue(highContrastPixels.allSatisfy {
            $0.style.background == theme.background
        })

        let ascii = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        var asciiCanvas = TerminalCanvas(
            size: DeltaMark.largeTerminalSize
        )
        DeltaMark.drawLarge(
            on: &asciiCanvas,
            row: 0,
            column: 0,
            theme: theme,
            capabilities: ascii
        )
        let asciiText = asciiCanvas.rows.flatMap { $0 }
            .filter { !$0.continuation }
            .map(\.text)
            .joined()
        XCTAssertTrue(asciiText.contains("#"))
        XCTAssertTrue(asciiText.contains("+"))
        XCTAssertTrue(asciiText.contains("@"))
        XCTAssertTrue(asciiText.contains("."))
        XCTAssertTrue(asciiCanvas.rows[10...18].flatMap { $0 }.contains {
            $0.text == "#"
        })
        XCTAssertFalse(asciiText.contains("█"))
        XCTAssertFalse(asciiText.contains("▀"))
        XCTAssertFalse(asciiText.contains("▄"))
    }

    func testBrandAndAnimationRemainBoundedOnLightAndDarkThemes() {
        let themes = [
            TerminalTheme(
                background: .rgb(18, 18, 20),
                text: .rgb(245, 245, 247)
            ),
            TerminalTheme(
                background: .rgb(250, 250, 250),
                text: .rgb(24, 24, 26)
            ),
        ]
        let capabilityVariants = [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .indexed256,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: false
            ),
        ]
        XCTAssertEqual(TerminalTheme().background, .default)

        for theme in themes {
            for capabilities in capabilityVariants {
                var brand = TerminalCanvas(
                    size: DeltaMark.largeTerminalSize,
                    fill: theme.style(
                        .normal,
                        highContrast: capabilities.highContrast
                    )
                )
                DeltaMark.drawLarge(
                    on: &brand,
                    row: 0,
                    column: 0,
                    theme: theme,
                    capabilities: capabilities
                )
                let brandPixels = brand.rows.flatMap { $0 }
                    .filter { $0.text != " " }
                XCTAssertFalse(brandPixels.isEmpty)
                XCTAssertTrue(brandPixels.allSatisfy {
                    $0.style.background == theme.background
                })

                for tick in 0..<OperationPixelAnimation.Frame.phaseCount {
                    var animation = TerminalCanvas(
                        size: TerminalSize(
                            columns: OperationPixelAnimation.Frame.width,
                            rows: OperationPixelAnimation.Frame.height
                        ),
                        fill: theme.style(
                            .normal,
                            highContrast: capabilities.highContrast
                        )
                    )
                    OperationPixelAnimation.draw(
                        OperationPixelAnimation.frame(
                            for: .compare,
                            tick: tick,
                            capabilities: capabilities
                        ),
                        on: &animation,
                        row: 0,
                        column: 0,
                        theme: theme,
                        capabilities: capabilities
                    )
                    XCTAssertEqual(
                        animation.rows.count,
                        OperationPixelAnimation.Frame.height
                    )
                    XCTAssertTrue(animation.rows.allSatisfy {
                        $0.count == OperationPixelAnimation.Frame.width
                    })
                    XCTAssertTrue(
                        animation.rows.flatMap { $0 }
                            .filter { $0.text != " " }
                            .allSatisfy {
                                $0.style.background == theme.background
                            }
                    )
                }
            }
        }
    }

    func testHomeBrandingStaysBalancedAtSupportedInspectionSizes() {
        var settings = TUISettings()
        settings.workflow.projectRoot = "/Synthetic/UpgradeSample"
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: true
        )
        state.projectWasExplicitlySelected = true
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: false,
            mouseSupported: true
        )
        for theme in [
            TerminalTheme(
                background: .rgb(18, 18, 20),
                text: .rgb(245, 245, 247)
            ),
            TerminalTheme(
                background: .rgb(250, 250, 250),
                text: .rgb(24, 24, 26)
            ),
        ] {
            let renderer = TUIScreenRenderer(
                theme: theme,
                capabilities: capabilities
            )
            for size in [
                TerminalSize(columns: 80, rows: 24),
                TerminalSize(columns: 100, rows: 28),
                TerminalSize(columns: 128, rows: 32),
                TerminalSize(columns: 160, rows: 50),
            ] {
                let canvas = renderer.render(state, size: size)
                let text = canvas.rows.flatMap { $0 }
                    .filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                XCTAssertEqual(canvas.rows.count, size.rows)
                XCTAssertTrue(canvas.rows.allSatisfy {
                    $0.count == size.columns
                })
                XCTAssertTrue(text.contains("Doctor"), "\(size)")
                XCTAssertTrue(text.contains("Analysis"), "\(size)")
                XCTAssertTrue(text.contains("Repair"), "\(size)")
                XCTAssertTrue(
                    text.contains("█")
                        || text.contains("▀")
                        || text.contains("▄"),
                    "\(size)"
                )
            }
        }
    }

    func testOperationPixelAnimationUsesStableAccessibleVariants() {
        let operations: [TUIOperationKind] = [
            .automaticSetup, .discover, .doctor, .scan, .compare,
            .planRepair, .applyRepair, .exportReport, .exportRepairPlan,
            .cacheStatus, .cachePrune, .cacheClear,
        ]
        let unicode = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: false,
            mouseSupported: true
        )
        for operation in operations {
            let frames = (0..<OperationPixelAnimation.Frame.phaseCount).map {
                OperationPixelAnimation.frame(
                    for: operation,
                    tick: $0,
                    capabilities: unicode
                )
            }
            XCTAssertEqual(
                Set(frames.map(\.phase)),
                Set(0..<OperationPixelAnimation.Frame.phaseCount)
            )
            XCTAssertEqual(Set(frames.map(\.caption)).count, 1)
            XCTAssertGreaterThan(Set(frames).count, 6)
            for frame in frames {
                XCTAssertFalse(frame.cells.isEmpty)
                XCTAssertTrue(frame.cells.allSatisfy {
                    (0..<OperationPixelAnimation.Frame.height)
                        .contains($0.row)
                        && (0..<OperationPixelAnimation.Frame.width)
                            .contains($0.column)
                })
                XCTAssertTrue(frame.cells.contains { $0.tone == .shadow })
            }
            XCTAssertTrue(frames[4].cells.contains { $0.tone == .baseline })
            XCTAssertFalse(frames[4].cells.contains {
                $0.tone == .candidate || $0.tone == .candidateDepth
            })
            XCTAssertTrue(frames[4].cells.contains {
                $0.tone == .code
            })
            XCTAssertFalse(frames[14].cells.contains {
                $0.tone == .baseline || $0.tone == .baselineDepth
            })
            XCTAssertTrue(frames[14].cells.contains {
                $0.tone == .candidate
            })
            XCTAssertTrue(frames[14].cells.contains {
                $0.tone == .code
            })
            XCTAssertTrue(frames[8...11].allSatisfy {
                $0.cells.contains { $0.tone == .stream }
            })
            XCTAssertTrue(frames[20...23].allSatisfy {
                $0.cells.contains { $0.tone == .stream }
            })
            let forwardFlow = frames[8...11].compactMap {
                $0.cells.filter { $0.tone == .stream }.map(\.column).min()
            }
            XCTAssertEqual(forwardFlow, forwardFlow.sorted())
            let reverseFlow = frames[20...23].compactMap {
                $0.cells.filter { $0.tone == .stream }.map(\.column).max()
            }
            XCTAssertEqual(reverseFlow, reverseFlow.sorted(by: >))
            let activeFrames = Array(frames[0...7])
                + Array(frames[12...19])
            XCTAssertTrue(activeFrames.allSatisfy {
                !$0.cells.contains { $0.tone == .stream }
            })
            XCTAssertTrue(frames.allSatisfy {
                $0.cells.filter { $0.tone != .shadow }.allSatisfy {
                    (7...22).contains($0.column)
                }
            })
            XCTAssertEqual(
                OperationPixelAnimation.frame(
                    for: operation,
                    tick: OperationPixelAnimation.Frame.phaseCount,
                    capabilities: unicode
                ),
                frames[0]
            )
            XCTAssertEqual(
                OperationPixelAnimation.frame(
                    for: operation,
                    tick: -1,
                    capabilities: unicode
                ),
                frames[OperationPixelAnimation.Frame.phaseCount - 1]
            )
        }

        var reduced = unicode
        reduced.reducedMotion = true
        let reducedFirst = OperationPixelAnimation.frame(
            for: .planRepair,
            tick: 0,
            capabilities: reduced
        )
        let reducedLater = OperationPixelAnimation.frame(
            for: .planRepair,
            tick: 50,
            capabilities: reduced
        )
        XCTAssertEqual(reducedFirst, reducedLater)
        XCTAssertEqual(reducedFirst.caption, "PLAN in progress")
        XCTAssertTrue(reducedFirst.cells.contains {
            $0.tone == .candidate
        })
        XCTAssertFalse(reducedFirst.cells.contains {
            $0.tone == .baseline || $0.tone == .baselineDepth
        })
        XCTAssertFalse(reducedFirst.cells.contains {
            $0.tone == .code
                || $0.tone == .stream
        })

        var ascii = unicode
        ascii.symbolMode = .ascii
        let asciiFrame = OperationPixelAnimation.frame(
            for: .applyRepair,
            tick: 3,
            capabilities: ascii
        )
        XCTAssertTrue(asciiFrame.cells.contains { $0.character == ":" })
        XCTAssertTrue(asciiFrame.cells.contains { $0.character == "." })
        XCTAssertTrue(asciiFrame.cells.contains {
            ["{", "}", "<", ">", "/", "=", "+"].contains($0.character)
        })
        XCTAssertFalse(asciiFrame.cells.contains {
            ["█", "▀", "▄"].contains($0.character)
        })

        var animationCanvas = TerminalCanvas(
            size: TerminalSize(
                columns: OperationPixelAnimation.Frame.width,
                rows: OperationPixelAnimation.Frame.height
            )
        )
        var foregrounds: [TerminalColor] = []
        for tick in [4, 10, 14] {
            animationCanvas = TerminalCanvas(
                size: TerminalSize(
                    columns: OperationPixelAnimation.Frame.width,
                    rows: OperationPixelAnimation.Frame.height
                )
            )
            OperationPixelAnimation.draw(
                OperationPixelAnimation.frame(
                    for: .compare,
                    tick: tick,
                    capabilities: unicode
                ),
                on: &animationCanvas,
                row: 0,
                column: 0,
                theme: TerminalTheme(),
                capabilities: unicode
            )
            foregrounds.append(
                contentsOf: animationCanvas.rows.flatMap { $0 }
                    .filter { $0.text != " " }
                    .compactMap(\.style.foreground)
            )
        }
        XCTAssertTrue(foregrounds.contains(DeltaMark.brandColor))
        XCTAssertTrue(foregrounds.contains(DeltaMark.candidateDepthColor))
        XCTAssertTrue(
            foregrounds.contains(DeltaMark.candidateHighlightColor)
        )
        XCTAssertTrue(foregrounds.contains(DeltaMark.baselineColor))
        XCTAssertTrue(foregrounds.contains(DeltaMark.baselineDepthColor))
        XCTAssertTrue(foregrounds.contains(DeltaMark.shadowColor))
    }

    func testOperationProgressBarUsesMeasuredAndAccessibleStates() {
        let theme = TerminalTheme()
        let trueColor = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: false,
            mouseSupported: true
        )
        let measurement = OperationProgressMeasurement(
            completed: 3,
            total: 4,
            label: "SDK modules"
        )
        var measured = TerminalCanvas(
            size: TerminalSize(columns: 40, rows: 1)
        )
        OperationProgressBar.draw(
            measurement: measurement,
            tick: 0,
            on: &measured,
            row: 0,
            column: 0,
            width: 40,
            theme: theme,
            capabilities: trueColor
        )
        let measuredCells = measured.rows[0]
        XCTAssertTrue(measuredCells.allSatisfy { $0.text == "█" })
        XCTAssertTrue(measuredCells.prefix(30).allSatisfy {
            $0.style.foreground == DeltaMark.brandColor
        })
        XCTAssertTrue(measuredCells.suffix(10).allSatisfy {
            $0.style.foreground != DeltaMark.brandColor
        })
        XCTAssertEqual(
            OperationProgressBar.label(
                for: measurement,
                capabilities: trueColor
            ),
            "SDK modules  3 of 4 · 75%"
        )
        var firstUnknown = TerminalCanvas(
            size: TerminalSize(columns: 40, rows: 1)
        )
        var laterUnknown = firstUnknown
        OperationProgressBar.draw(
            measurement: nil,
            tick: 4,
            on: &firstUnknown,
            row: 0,
            column: 0,
            width: 40,
            theme: theme,
            capabilities: trueColor
        )
        OperationProgressBar.draw(
            measurement: nil,
            tick: 9,
            on: &laterUnknown,
            row: 0,
            column: 0,
            width: 40,
            theme: theme,
            capabilities: trueColor
        )
        XCTAssertNotEqual(firstUnknown.rows, laterUnknown.rows)
        XCTAssertLessThanOrEqual(
            firstUnknown.rows[0].filter {
                $0.style.foreground == DeltaMark.brandColor
            }.count,
            5
        )

        for colorMode in TerminalColorMode.allCases {
            for symbolMode in [TerminalSymbolMode.unicode, .ascii] {
                for reducedMotion in [false, true] {
                    let capabilities = TerminalCapabilities(
                        colorMode: colorMode,
                        symbolMode: symbolMode,
                        highContrast: colorMode == .monochrome,
                        reducedMotion: reducedMotion,
                        mouseSupported: false
                    )
                    var canvas = TerminalCanvas(
                        size: TerminalSize(columns: 23, rows: 1)
                    )
                    OperationProgressBar.draw(
                        measurement: nil,
                        tick: 12,
                        on: &canvas,
                        row: 0,
                        column: 0,
                        width: 23,
                        theme: theme,
                        capabilities: capabilities
                    )
                    XCTAssertEqual(canvas.rows[0].count, 23)
                    XCTAssertTrue(canvas.rows[0].allSatisfy {
                        symbolMode == .ascii
                            ? ["=", "-"].contains($0.text)
                            : $0.text == "█"
                    })
                    XCTAssertTrue(canvas.rows[0].allSatisfy {
                        $0.style.background == theme.background
                    })
                }
            }
        }

        var reduced = trueColor
        reduced.reducedMotion = true
        var reducedFirst = TerminalCanvas(
            size: TerminalSize(columns: 40, rows: 1)
        )
        var reducedLater = reducedFirst
        OperationProgressBar.draw(
            measurement: nil,
            tick: 0,
            on: &reducedFirst,
            row: 0,
            column: 0,
            width: 40,
            theme: theme,
            capabilities: reduced
        )
        OperationProgressBar.draw(
            measurement: nil,
            tick: 100,
            on: &reducedLater,
            row: 0,
            column: 0,
            width: 40,
            theme: theme,
            capabilities: reduced
        )
        XCTAssertEqual(reducedFirst.rows, reducedLater.rows)
    }

    func testMinimumSizeViewDoesNotRenderOutsideBounds() {
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.settings.appearance.reducedMotion = true
        let capabilities = TerminalCapabilities.detect(environment: [
            "TERM": "dumb", "LANG": "C",
        ])
        let canvas = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).render(state, size: TerminalSize(columns: 20, rows: 4))

        XCTAssertEqual(canvas.rows.count, 4)
        XCTAssertTrue(canvas.rows.allSatisfy { $0.count == 20 })
    }

    func testDifferentialRendererWritesOnlyChangedRows() throws {
        let directory = try TUITestDirectory()
        let outputURL = directory.url.appendingPathComponent("terminal.capture")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ))
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let renderer = DifferentialTerminalRenderer(output: output)
        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        let theme = TerminalTheme()
        var canvas = TerminalCanvas(
            size: TerminalSize(columns: 12, rows: 2)
        )
        canvas.write(
            "first",
            row: 0,
            column: 0,
            style: .plain
        )

        renderer.render(
            canvas,
            theme: theme,
            capabilities: capabilities
        )
        try output.synchronize()
        let firstSize = try Data(contentsOf: outputURL).count
        renderer.render(
            canvas,
            theme: theme,
            capabilities: capabilities
        )
        try output.synchronize()
        XCTAssertEqual(try Data(contentsOf: outputURL).count, firstSize)

        canvas.write(
            "changed",
            row: 1,
            column: 0,
            style: .plain
        )
        renderer.render(
            canvas,
            theme: theme,
            capabilities: capabilities
        )
        try output.synchronize()
        XCTAssertGreaterThan(try Data(contentsOf: outputURL).count, firstSize)
    }

}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
