// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import WireOpenAPIMacros

/// `@OpenAPIController` is a marker: it expands to nothing. The conformance it used to generate moved to
/// `WireOpenAPIGen`, which emits it on the plugin-synthesised aggregate proxy — the only place it can go
/// once one proxy serves a whole spec, and the only place Swift permits it at all (`TransportContributor`
/// refines `Sendable`, whose conformance must be in the type's own file).
///
/// What the attribute *directs* is exercised end-to-end by `WireOpenAPIExample`, which builds through the
/// real plugin; there is nothing left for a macro-expansion test to assert beyond the marker being inert.
/// The witness's access level, which these tests used to pin, is no longer a concern either: the proxy is
/// emitted `internal` into the consumer module, so its witness never has to match a controller's access.
final class OpenAPIControllerMacroTests: XCTestCase {
    private let macros: [String: any Macro.Type] = ["OpenAPIController": OpenAPIControllerMacro.self]

    func testMarkerExpandsToNothing() {
        assertMacroExpansion(
            """
            @OpenAPIController
            struct TaskController {}
            """,
            expandedSource: """
                struct TaskController {}
                """,
            macros: macros
        )
    }

    func testSpecFormExpandsToNothing() {
        assertMacroExpansion(
            """
            @OpenAPIController(spec: "TaskAPI")
            public struct TaskController {}
            """,
            expandedSource: """
                public struct TaskController {}
                """,
            macros: macros
        )
    }
}
