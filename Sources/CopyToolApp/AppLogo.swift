import CopyToolCore
import AppKit
import SwiftUI

/// 图标由打包脚本放入主 bundle，侧栏与使用说明复用同一品牌资源。
struct AppLogo: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let size: CGFloat
    private static let image: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        let _ = appLanguage.language
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "bolt.fill").resizable().scaledToFit().foregroundStyle(.blue).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L10n.text("闪传 Logo"))
    }
}
