import CoreGraphics
import Foundation
import Testing
@testable import MentorE2E

@Suite struct BarGeometryTests {
    private func item(_ app: String, x: Double, width: Double) -> BarItem {
        BarItem(app: app, pid: 1, title: app, frame: CGRect(x: x, y: 4.5, width: width, height: 24))
    }

    @Test func sortsLeftToRight() {
        let items = [item("Mentor", x: 1250, width: 85), item("Wi-Fi", x: 1100, width: 30)]
        #expect(BarGeometry.sorted(items).map(\.app) == ["Wi-Fi", "Mentor"])
    }

    @Test func clickTargetIsTheItemCentreOnWholePixels() {
        let target = BarGeometry.centre(of: CGRect(x: 1250, y: 4.5, width: 85.5, height: 24))
        #expect(target == CGPoint(x: 1293, y: 17))
    }

    @Test func gapsMeasureTheSpaceBetweenNeighbours() {
        let gaps = BarGeometry.gaps([
            item("Wi-Fi", x: 1100, width: 30),
            item("Control Center", x: 1136, width: 30),
            item("Mentor", x: 1172, width: 85),
        ])
        #expect(gaps.count == 2)
        #expect(gaps[0].left.app == "Wi-Fi")
        #expect(gaps[0].gap == 6)
        #expect(gaps[1].right.app == "Mentor")
        #expect(gaps[1].gap == 6)
    }

    @Test func aNarrowerItemShowsUpAsMovedNeighbours() {
        // The deviation the visible-bar check found: Mentor's item shrinks by
        // 5 pt in an excluded app, so everything left of it slides right.
        let watching = [item("Wi-Fi", x: 1100, width: 30), item("Mentor", x: 1136, width: 85.5)]
        let excluded = [item("Wi-Fi", x: 1105, width: 30), item("Mentor", x: 1141, width: 80.5)]
        #expect(BarGeometry.gaps(watching)[0].gap == BarGeometry.gaps(excluded)[0].gap)
        #expect(BarGeometry.sorted(watching)[0].frame.minX != BarGeometry.sorted(excluded)[0].frame.minX)
    }

    @Test func findsTheItemUnderAPoint() {
        let items = [item("Wi-Fi", x: 1100, width: 30), item("Mentor", x: 1136, width: 85)]
        #expect(BarGeometry.item(at: CGPoint(x: 1178, y: 17), in: items)?.app == "Mentor")
        #expect(BarGeometry.item(at: CGPoint(x: 1133, y: 17), in: items) == nil)
    }

    @Test func emptyPointSitsBetweenTheMenuTitlesAndTheExtras() {
        let titles = [item("TextEdit", x: 60, width: 40), item("File", x: 110, width: 34)]
        let extras = [item("Wi-Fi", x: 1100, width: 30)]
        let point = BarGeometry.emptyPoint(menuTitles: titles, extras: extras)
        #expect(point == CGPoint(x: 622, y: 17))
        #expect(BarGeometry.item(at: point!, in: titles + extras) == nil)
    }

    @Test func noEmptyPointWhenTheBarIsFull() {
        let titles = [item("TextEdit", x: 60, width: 40)]
        let extras = [item("Wi-Fi", x: 110, width: 30)]
        #expect(BarGeometry.emptyPoint(menuTitles: titles, extras: extras) == nil)
        #expect(BarGeometry.emptyPoint(menuTitles: [], extras: extras) == nil)
        #expect(BarGeometry.emptyPoint(menuTitles: titles, extras: []) == nil)
    }
}
