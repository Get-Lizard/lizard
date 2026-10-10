// Renders the app icon PNGs and the menu-bar template image from the Swift geometry.
// Run: scripts/make-icons.sh
import AppKit
import SwiftUI

@MainActor func png<V: View>(_ view: V, scale: CGFloat) -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
}

@main struct RenderBrand {
    @MainActor static func main() throws {
        let root = URL(filePath: CommandLine.arguments[1])
        let icons = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset")
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            // macOS icons sit inside a ~10% transparent margin.
            let canvas = CGFloat(pixels)
            let view = LizardAppIcon(size: canvas * 0.805).frame(width: canvas, height: canvas)
            try png(view, scale: 1).write(to: icons.appending(path: "icon_\(pixels).png"))
        }
        let menu = root.appending(path: "App/Assets.xcassets/MenuBarIcon.imageset")
        for scale in [1, 2] {
            let view = LizardMark(style: Color.black).frame(width: 18, height: 18)
            try png(view, scale: CGFloat(scale)).write(to: menu.appending(path: "menubar@\(scale)x.png"))
        }
        try png(LizardAppIcon(size: 1024), scale: 1).write(to: root.appending(path: "docs/brand/lizard-app-icon-1024.png"))
        try png(SplashView(firstLaunch: true, preview: true) {}, scale: 2).write(to: root.appending(path: "docs/brand/splash.png"))
        print("rendered")
    }
}
