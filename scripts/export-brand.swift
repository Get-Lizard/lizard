// Exports web/GitHub brand assets from the app's own Swift geometry.
// Run: scripts/export-brand.sh
import AppKit
import SwiftUI

func svgPath(_ path: CGPath) -> String {
    var parts: [String] = []
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: parts.append("M\(f(p[0].x)) \(f(p[0].y))")
        case .addLineToPoint: parts.append("L\(f(p[0].x)) \(f(p[0].y))")
        case .addQuadCurveToPoint: parts.append("Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))")
        case .addCurveToPoint: parts.append("C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))")
        case .closeSubpath: parts.append("Z")
        @unknown default: break
        }
    }
    return parts.joined(separator: " ")
}

@MainActor func png<V: View>(_ view: V, scale: CGFloat = 1) -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
}

@main struct ExportBrand {
    @MainActor static func main() throws {
        let root = URL(filePath: CommandLine.arguments[1])
        let brand = root.appending(path: "docs/brand")
        let site = root.appending(path: "website/assets")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

        let silhouette = svgPath(LizardGeometry.silhouette(.init()).cgPath)
        let centerline = svgPath(LizardGeometry.centerline(.init()).cgPath)
        let mark = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">\
            <stop offset="0" stop-color="#3DDC84"/><stop offset="1" stop-color="#14B8A6"/></linearGradient></defs>\
            <path fill="url(#g)" fill-rule="evenodd" d="\(silhouette)"/></svg>
            """
        try mark.write(to: brand.appending(path: "lizard-mark.svg"), atomically: true, encoding: .utf8)
        try mark.replacingOccurrences(of: "url(#g)", with: "#F4F1EA").write(to: brand.appending(path: "lizard-mark-white.svg"), atomically: true, encoding: .utf8)
        try mark.write(to: site.appending(path: "lizard-mark.svg"), atomically: true, encoding: .utf8)
        // Path data (the website embeds these in index.html's inline SVG).
        try "{\"silhouette\":\"\(silhouette)\",\"centerline\":\"\(centerline)\"}".write(to: brand.appending(path: "lizard-paths.json"), atomically: true, encoding: .utf8)

        // Organization avatar: full-bleed square (GitHub crops it), ink + glow + gradient gecko.
        let avatar = ZStack {
            Brand.ink
            RadialGradient(colors: [Brand.moss.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 330)
            LizardMark(style: Brand.gradient).padding(70).shadow(color: Brand.moss.opacity(0.5), radius: 14)
        }.frame(width: 512, height: 512)
        try png(avatar).write(to: brand.appending(path: "org-avatar-512.png"))

        // Social preview (repo card / Open Graph): 1280×640.
        let social = ZStack {
            Brand.ink
            RadialGradient(colors: [Brand.moss.opacity(0.28), .clear], center: .init(x: 0.25, y: 0.5), startRadius: 0, endRadius: 520)
            HStack(spacing: 48) {
                LizardMark(style: Brand.gradient).frame(width: 300, height: 300).shadow(color: Brand.moss.opacity(0.5), radius: 18)
                VStack(alignment: .leading, spacing: 14) {
                    Text("lizard").font(.system(size: 110, weight: .semibold, design: .rounded)).foregroundStyle(Brand.sand)
                    Text("Smart search for your Mac.").font(.system(size: 38, weight: .medium, design: .rounded)).foregroundStyle(Brand.sand.opacity(0.85))
                    Text("Local AI · Notes · Clipboard · Screenshots · Raycast extensions").font(.system(size: 22, weight: .medium)).foregroundStyle(Brand.moss)
                }
            }
        }.frame(width: 1280, height: 640)
        let socialData = png(social)
        try socialData.write(to: brand.appending(path: "social-preview.png"))
        try socialData.write(to: site.appending(path: "social-preview.png"))
        try png(LizardAppIcon(size: 512)).write(to: site.appending(path: "app-icon.png"))
        try FileManager.default.copyItem(at: brand.appending(path: "splash.png"), to: site.appending(path: "splash.png"))
        print("exported")
    }
}
