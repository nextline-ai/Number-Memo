import XCTest
import SwiftUI
@testable import NumberMemo

final class GridLayoutTests: XCTestCase {
    @MainActor func testAutomaticAndManualColumnsFollowContainerWidth() async throws {
        // Render the real shared grid at phone, split-window, and full iPad/Mac widths.
        for (width, setting, expected) in [(390.0, 0, 2), (768, 0, 4), (1024, 0, 5), (1366, 0, 7), (390, 3, 3), (1024, 2, 2)] {
            var frames: [Int: CGRect] = [:]
            let view = GridProbe(columns: setting) { frames = $0 }.frame(width: width, height: 900)
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let first = try XCTUnwrap(frames[0], "width \(width)")
            let row = frames.values.filter { abs($0.minY - first.minY) < 1 }
            XCTAssertEqual(row.count, expected, "width \(width), setting \(setting)")
            XCTAssertTrue(frames.values.allSatisfy { $0.minX >= 15 && $0.maxX <= width - 15 })
        }
    }

    @MainActor func testAutomaticPersistsAndModesKeepIndependentChoices() throws {
        let suite = "grid-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory()
        let store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.gridColumns, 0)
        env.mode = .hitomi; env.gridColumns = 2
        env.mode = .booru; env.gridColumns = 3
        env.mode = .hitomi; XCTAssertEqual(env.gridColumns, 2)
        env.gridColumns = 0
        let reopened = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(reopened.gridColumns, 0)
        reopened.mode = .booru; XCTAssertEqual(reopened.gridColumns, 3)
    }
}

private struct GridFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridProbe: View {
    let columns: Int
    let report: ([Int: CGRect]) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: WorkGridLayout.columns(columns), spacing: 14) {
                ForEach(0..<14) { index in
                    Color.blue.frame(height: 80).background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: GridFrames.self, value: [index: geometry.frame(in: .named("grid"))])
                        }
                    }
                }
            }.padding(16)
        }.coordinateSpace(name: "grid").onPreferenceChange(GridFrames.self, perform: report)
    }
}
