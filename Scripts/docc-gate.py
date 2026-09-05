#!/usr/bin/env python3
"""Fail on DocC diagnostics that belong to this package.

The build runs without `--warnings-as-errors` and its structured diagnostics are
filtered here: anything whose source is a file in this repository, and not a
dependency checkout under `.build`, fails the job. A broken link in this
package's own doc comments or catalog is caught; a diagnostic DocC raises against
a dependency's symbols — which a `public import` can pull into this module's
symbol graph, and which this package cannot fix — is not this package's to answer
for.
"""

import json
import os
import pathlib
import sys

diagnostics_file = sys.argv[1]
root = pathlib.Path(os.getcwd()).resolve()

diagnostics = json.load(open(diagnostics_file)).get("diagnostics", [])

own = []
for diagnostic in diagnostics:
    source = diagnostic.get("source")
    if not source:
        # No source location — nothing ties it to a file in this package.
        continue
    path = pathlib.Path(source.removeprefix("file://")).resolve()
    if root in path.parents and ".build" not in path.parts:
        own.append((path.relative_to(root), diagnostic))

for path, diagnostic in own:
    print(f"{path}: {diagnostic.get('severity')}: {diagnostic.get('summary')}")

print(f"\n{len(own)} diagnostic(s) in this package's own sources ({len(diagnostics)} total).")
sys.exit(1 if own else 0)
