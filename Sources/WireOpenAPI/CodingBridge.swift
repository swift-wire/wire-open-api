public import Foundation
@_spi(Generated) public import OpenAPIRuntime
public import WireMVC

// Bridging WireMVC's coding settings onto the OpenAPI runtime's `Configuration`.
//
// This is what makes the unification real for a value an app actually notices. Before it, a `@Get` route
// and an OpenAPI operation in the same app wrote dates differently — Foundation's default is a number
// since 2001, the runtime's is ISO8601 — and nothing connected the two. The settings now arrive at
// `registerWireRoutes(on:coding:)` from the composition root and are turned into the `Configuration` the
// operation's `UniversalServer` is built with, so both kinds of route answer the same way.

/// A `DateTranscoder` backed by WireMVC's.
///
/// The two protocols have the same two requirements, which is not a coincidence: `DateTranscoding` was
/// shaped this way so the bridge would be a forwarding wrapper rather than a translation with judgement
/// in it.
struct WireMVCDateTranscoder: DateTranscoder {
    let dates: any DateTranscoding

    func encode(_ date: Date) throws -> String { try dates.encode(date) }
    func decode(_ string: String) throws -> Date { try dates.decode(string) }
}

extension Configuration {
    /// The runtime configuration these coding settings describe.
    ///
    /// The mapping is total in both directions: `JSONEncodingOptions` has exactly three members, and
    /// `JSONCoding` now has a setting for each. That is worth stating because it is the property that
    /// makes routing OpenAPI coding through the shared tier safe — nothing is silently dropped on the way
    /// through, so an app configures its dates and its JSON once and both kinds of route obey it.
    ///
    /// The **defaults** deliberately differ from the runtime's, which are `[.sortedKeys, .prettyPrinted]`.
    /// An app that says nothing now gets compact, unsorted output from its operations where it previously
    /// got indented, sorted output. That is the point rather than a side effect: the app's settings win,
    /// and one document's generated code no longer formats its responses unlike the route next to it.
    public init(wireMVCCoding coding: WireMVCCoding) {
        var options: JSONEncodingOptions = []
        if coding.json.sortsKeys { options.insert(.sortedKeys) }
        if !coding.json.escapesSlashes { options.insert(.withoutEscapingSlashes) }
        if coding.json.prettyPrints { options.insert(.prettyPrinted) }
        self.init(
            dateTranscoder: WireMVCDateTranscoder(dates: coding.dates),
            jsonEncodingOptions: options
        )
    }
}
