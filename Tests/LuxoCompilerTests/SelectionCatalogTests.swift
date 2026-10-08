import Foundation
import XCTest
@testable import LuxoCompiler

final class SelectionCatalogTests: XCTestCase {
    func testResolvesOnlyManifestSymbolsAndRejectsMissingEntries() throws {
        let manifest =
            #"{"version":1,"module":"SDK","client":"Client","apis":{"user":{}},"fields":{"User":{"id":false}}}"#
        let graph =
            #"{"module":{"name":"SDK"},"symbols":[{"identifier":{"precise":"exact.api"},"pathComponents":["Client","user(select:)"]},{"identifier":{"precise":"other.api"},"pathComponents":["Other","user(select:)"]},{"identifier":{"precise":"exact.field"},"pathComponents":["User","id"]}]}"#
        let catalog = try SelectionCatalog(manifest: Data(manifest.utf8), graphs: [Data(graph.utf8)])
        XCTAssertEqual(Set(catalog.apis.keys), ["exact.api"])
        XCTAssertEqual(catalog.fields["exact.field"]?.name, "id")
        XCTAssertThrowsError(try SelectionCatalog(manifest: Data(manifest.utf8), graphs: []))
        XCTAssertThrowsError(
            try SelectionCatalog(
                manifest: Data(manifest.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8),
                graphs: [Data(graph.utf8)]))
    }
}
