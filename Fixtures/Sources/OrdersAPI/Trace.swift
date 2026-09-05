// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation

/// Trace lines the CI probe asserts on, written to **stderr**.
///
/// They are the fixture's evidence: a middleware or a scope entry that silently does not run still
/// produces a correct response, so the log is the only thing that can tell the difference. stdout is
/// block-buffered when redirected to a file, so a probe that kills the server loses whatever had not
/// flushed and every one of those assertions fails for a reason unrelated to the code. stderr is
/// unbuffered, which makes that independent of how the process was launched — and unlike `setvbuf`, it
/// needs no reference to the `stdout` global, which on Glibc is a `var` and not concurrency-safe.
func trace(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
