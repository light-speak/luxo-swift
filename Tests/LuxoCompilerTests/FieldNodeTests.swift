import XCTest
@testable import LuxoCompiler

final class FieldNodeTests: XCTestCase {
    func testFieldNodeProducesCanonicalSortedSelection() {
        let root = FieldNode.root()
        root.addChild("name")
        root.addChild("comments").addChild("text")
        root.addChild("comments").addChild("author").addChild("id")
        root.addChild("id")

        XCTAssertEqual(root.maxDepth(), 3)
        XCTAssertEqual(root.toSelectString(), "comments{author{id},text},id,name")
    }

}
