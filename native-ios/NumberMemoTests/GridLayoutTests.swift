import XCTest
import SwiftUI
@testable import NumberMemo

final class GridLayoutTests: XCTestCase {
    @MainActor func testAutomaticAndManualColumnsFollowContainerWidth() async throws {
        // Render the real shared grid at phone, split-window, and full iPad/Mac widths.
        for (width, setting, minimum, expected) in [(390.0, 0, 160.0, 2), (768, 0, 160, 4), (1024, 0, 160, 5), (1366, 0, 160, 7), (390, 3, 160, 3), (1024, 2, 160, 2), (768, 0, 240, 2), (1024, 0, 240, 3), (1366, 0, 240, 5)] {
            var frames: [Int: CGRect] = [:]
            let view = GridProbe(columns: setting, minimum: minimum) { frames = $0 }.frame(width: width, height: 900)
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

    @MainActor func testFolderPreviewHeightGrowsWithWidth() throws {
        let folder = try XCTUnwrap(try AppDatabase.inMemory().listFolders().first)
        let host = UIHostingController(rootView: FolderBentoCardView(folder: folder))
        let small = host.sizeThatFits(in: CGSize(width: 180, height: 2000))
        let large = host.sizeThatFits(in: CGSize(width: 360, height: 2000))
        XCTAssertEqual(large.height - small.height, (360 - 180) / 1.25, accuracy: 2)
    }

    @MainActor func testAutomaticPersistsAndModesKeepIndependentChoices() throws {
        let suite = "grid-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory()
        let store = try BooruStore()
        let env = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(env.gridColumns, 0)
        env.mode = .hitomi; env.gridColumns = 2; env.folderColumns = 1
        env.mode = .booru; env.gridColumns = 3; env.folderColumns = 4
        env.mode = .hitomi; XCTAssertEqual(env.gridColumns, 2)
        env.gridColumns = 0
        let reopened = AppEnvironment(database: database, browserPreferences: defaults, booru: store)
        XCTAssertEqual(reopened.gridColumns, 0)
        XCTAssertEqual(reopened.folderColumns, 1)
        reopened.mode = .booru; XCTAssertEqual(reopened.gridColumns, 3)
        XCTAssertEqual(reopened.folderColumns, 4)
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
    let minimum: CGFloat
    let report: ([Int: CGRect]) -> Void
    var body: some View {
        ScrollView {
            LazyVGrid(columns: WorkGridLayout.columns(columns, minimum: minimum), spacing: 14) {
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
