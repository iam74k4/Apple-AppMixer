import XCTest
@testable import AppMixer

final class WindowHeightSyncTests: XCTestCase {

    func testShrinkKeepsTopEdge() {
        // 高さ 580 のウインドウ（上端 y=1000）を、中身 289 に合わせる。
        let frame = NSRect(x: 100, y: 420, width: 420, height: 580)
        let fitted = try! XCTUnwrap(
            WindowHeightSync.fitted(frame: frame, contentHeight: 580, toContentHeight: 289))
        XCTAssertEqual(fitted.height, 289)
        XCTAssertEqual(fitted.maxY, frame.maxY)
        XCTAssertEqual(fitted.minX, frame.minX)
        XCTAssertEqual(fitted.width, frame.width)
    }

    func testGrowKeepsTopEdge() {
        let frame = NSRect(x: 0, y: 700, width: 420, height: 300)
        let fitted = try! XCTUnwrap(
            WindowHeightSync.fitted(frame: frame, contentHeight: 300, toContentHeight: 580))
        XCTAssertEqual(fitted.height, 580)
        XCTAssertEqual(fitted.maxY, 1000)
    }

    func testTitleBarHeightIsPreserved() {
        // 枠が中身より 20pt 高い（タイトルバー等）。差分だけを動かす。
        let frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        let fitted = try! XCTUnwrap(
            WindowHeightSync.fitted(frame: frame, contentHeight: 580, toContentHeight: 289))
        XCTAssertEqual(fitted.height, 309)
        XCTAssertEqual(fitted.maxY, 600)
    }

    func testSubPointDifferenceIsIgnored() {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 580)
        XCTAssertNil(WindowHeightSync.fitted(frame: frame, contentHeight: 580, toContentHeight: 580.4))
        XCTAssertNil(WindowHeightSync.fitted(frame: frame, contentHeight: 580, toContentHeight: 580))
    }
}
