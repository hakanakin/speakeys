// Renders the Speakeys app icon: a pink wireframe orb on a dark rounded square.
// Usage: swift make_icon.swift <output.icns>
import AppKit

struct Vec3 {
    var x, y, z: Double
    var normalized: Vec3 {
        let l = (x * x + y * y + z * z).squareRoot()
        return Vec3(x: x / l, y: y / l, z: z / l)
    }
}

func icosphere(_ subdivisions: Int) -> (verts: [Vec3], edges: [(Int, Int)]) {
    let t = (1 + 5.0.squareRoot()) / 2
    var verts = [
        Vec3(x: -1, y: t, z: 0), Vec3(x: 1, y: t, z: 0), Vec3(x: -1, y: -t, z: 0), Vec3(x: 1, y: -t, z: 0),
        Vec3(x: 0, y: -1, z: t), Vec3(x: 0, y: 1, z: t), Vec3(x: 0, y: -1, z: -t), Vec3(x: 0, y: 1, z: -t),
        Vec3(x: t, y: 0, z: -1), Vec3(x: t, y: 0, z: 1), Vec3(x: -t, y: 0, z: -1), Vec3(x: -t, y: 0, z: 1),
    ].map(\.normalized)
    var faces: [(Int, Int, Int)] = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
        (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
        (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]
    for _ in 0..<subdivisions {
        var cache: [Int: Int] = [:]
        func mid(_ a: Int, _ b: Int) -> Int {
            let key = min(a, b) * 1_000_000 + max(a, b)
            if let i = cache[key] { return i }
            let p = verts[a], q = verts[b]
            verts.append(Vec3(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2, z: (p.z + q.z) / 2).normalized)
            cache[key] = verts.count - 1
            return verts.count - 1
        }
        faces = faces.flatMap { f -> [(Int, Int, Int)] in
            let a = mid(f.0, f.1), b = mid(f.1, f.2), c = mid(f.2, f.0)
            return [(f.0, a, c), (f.1, b, a), (f.2, c, b), (a, b, c)]
        }
    }
    var seen = Set<Int>(), edges: [(Int, Int)] = []
    for f in faces {
        for (a, b) in [(f.0, f.1), (f.1, f.2), (f.2, f.0)] where seen.insert(min(a, b) * 1_000_000 + max(a, b)).inserted {
            edges.append((a, b))
        }
    }
    return (verts, edges)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background: macOS-style rounded square with a deep plum gradient
    let inset = s * 0.1
    let card = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: card, cornerWidth: card.width * 0.225, cornerHeight: card.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.16, green: 0.08, blue: 0.16, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.03, blue: 0.07, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Orb
    let mesh = icosphere(size >= 128 ? 3 : 2)
    let radius = Double(card.width) * 0.32
    let cx = Double(s / 2), cy = Double(s / 2)
    let (ay, ax) = (0.6, 0.45)
    var pts = [CGPoint](), depth = [Double]()
    for v in mesh.verts {
        let w = sin(3.1 * v.x + 0.8) * sin(2.7 * v.y + 1.7) * sin(2.3 * v.z + 0.6) + 0.5 * sin(4.3 * v.x + 3.7 * v.y)
        let r = 1 + 0.12 * w
        var x = v.x * r, y = v.y * r, z = v.z * r
        (x, z) = (x * cos(ay) + z * sin(ay), -x * sin(ay) + z * cos(ay))
        (y, z) = (y * cos(ax) - z * sin(ax), y * sin(ax) + z * cos(ax))
        let p = 3.2 / (3.2 + z)
        pts.append(CGPoint(x: cx + x * radius * p, y: cy + y * radius * p))
        depth.append(z)
    }
    let pink = NSColor(srgbRed: 1.0, green: 0.6, blue: 0.82, alpha: 1)
    let buckets = 5
    let paths = (0..<buckets).map { _ in CGMutablePath() }
    for (a, b) in mesh.edges {
        let k = min(max(Int(((depth[a] + depth[b]) / 2 + 1.5) / 3.0 * Double(buckets)), 0), buckets - 1)
        paths[k].move(to: pts[a])
        paths[k].addLine(to: pts[b])
    }
    ctx.setLineCap(.round)
    ctx.setLineWidth(max(0.6, s / 340))
    ctx.setShadow(offset: .zero, blur: s / 40, color: pink.withAlphaComponent(0.8).cgColor)
    for k in (0..<buckets).reversed() {
        ctx.setStrokeColor(pink.withAlphaComponent(0.95 - Double(k) / Double(buckets - 1) * 0.75).cgColor)
        ctx.addPath(paths[k])
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Speakeys-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
