// Renders the Mak8r Mail app icon (terracotta tile, cream envelope, olive fold) into an .iconset.
// Usage: swift Resources/Icon/AppIcon.swift <output.iconset>   (run via `make icon`)
import AppKit
import SwiftUI

let cream = Color(red: 0xF3/255, green: 0xE8/255, blue: 0xD6/255)
let olive = Color(red: 0x67/255, green: 0x61/255, blue: 0x49/255)
let terra = Color(red: 0x9A/255, green: 0x51/255, blue: 0x45/255)
let terraLight = Color(red: 0xAD/255, green: 0x5E/255, blue: 0x50/255)

struct Flap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Drawn on Apple's 1024 grid: 824pt continuous-corner tile, shadow on the tile only.
struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [terraLight, terra], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 3)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 44, style: .continuous).fill(cream)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                Flap().stroke(olive, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                    .frame(width: 520, height: 210)
                    .padding(.top, 34)
            }
            .frame(width: 590, height: 420)
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func write(size: Int, to url: URL) {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = CGFloat(size) / 1024
    let data = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

MainActor.assumeIsolated {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        write(size: base, to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
        write(size: base * 2, to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
