import AppKit
import SwiftUI
import XCTest
import CopyToolCore
@testable import CopyToolApp

final class UpdateProgressViewTests: XCTestCase {
    @MainActor func testProgressAndReadyFitNarrowSidebarInBothLanguagesWithoutInstalling() throws {
        let suite = "shanchuan-progress-ui." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: suite) }
        var installs = 0
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let progress = UpdateDownloadProgress(version: "0.2.4", assetName: "Shanchuan-0.2.4-win-x64-full.nupkg",
                downloadedBytes: 42_500_000, totalBytes: 85_000_000, isVerifying: false)
            XCTAssertEqual(progress.percentage, "50%")
            XCTAssertEqual(progress.amount, language == .english ? "Downloaded 42.5 MB / 85.0 MB" : "已下载 42.5 MB / 85.0 MB")
            let downloading = NSHostingView(rootView: UpdateDownloadProgressView(progress: progress).padding(12).frame(width: 190)
                .background(Color(nsColor: .windowBackgroundColor)))
            let ready = NSHostingView(rootView: UpdateInstallReadyView(version: "0.2.4", releaseNotes: "合成更新说明 / Synthetic release notes") {
                installs += 1
            }.padding(12).frame(width: 190).background(Color(nsColor: .windowBackgroundColor)))
            for (name, view) in [("download", downloading as NSView), ("ready", ready as NSView)] {
                let size = view.fittingSize
                XCTAssertEqual(size.width, 190, accuracy: 1)
                XCTAssertGreaterThan(size.height, 40)
                XCTAssertLessThan(size.height, 210, "Progress and ready actions must remain usable in a narrow sidebar")
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                if let directory = ProcessInfo.processInfo.environment["SHANCHUAN_UI_EVIDENCE_DIR"] {
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("update-\(name)-\(language.rawValue).png"))
                }
            }
        }
        XCTAssertEqual(installs, 0, "Layout and language changes must never count as installation approval")
    }
}
