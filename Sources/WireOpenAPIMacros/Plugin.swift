// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireOpenAPIMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [OpenAPIControllerMacro.self]
}
