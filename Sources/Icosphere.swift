import Foundation

/// Shared by the app's orb and the icon generator.

struct Vec3 {
    var x, y, z: Double

    var normalized: Vec3 {
        let length = (x * x + y * y + z * z).squareRoot()
        return Vec3(x: x / length, y: y / length, z: z / length)
    }

    func midpoint(_ other: Vec3) -> Vec3 {
        Vec3(x: (x + other.x) / 2, y: (y + other.y) / 2, z: (z + other.z) / 2)
    }
}

/// A unit sphere built by repeatedly subdividing an icosahedron. Each edge is listed once.
struct Icosphere {
    let vertices: [Vec3]
    let edges: [(Int, Int)]

    init(subdivisions: Int) {
        let t = (1 + 5.0.squareRoot()) / 2
        var vertices = [
            Vec3(x: -1, y: t, z: 0), Vec3(x: 1, y: t, z: 0), Vec3(x: -1, y: -t, z: 0), Vec3(x: 1, y: -t, z: 0),
            Vec3(x: 0, y: -1, z: t), Vec3(x: 0, y: 1, z: t), Vec3(x: 0, y: -1, z: -t), Vec3(x: 0, y: 1, z: -t),
            Vec3(x: t, y: 0, z: -1), Vec3(x: t, y: 0, z: 1), Vec3(x: -t, y: 0, z: -1), Vec3(x: -t, y: 0, z: 1),
        ].map(\.normalized)
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
            (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        func key(_ a: Int, _ b: Int) -> Int { min(a, b) << 32 | max(a, b) }

        for _ in 0..<subdivisions {
            var midpoints: [Int: Int] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                if let index = midpoints[key(a, b)] { return index }
                vertices.append(vertices[a].midpoint(vertices[b]).normalized)
                midpoints[key(a, b)] = vertices.count - 1
                return vertices.count - 1
            }
            faces = faces.flatMap { a, b, c in
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                return [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
        }

        var seen = Set<Int>()
        var edges: [(Int, Int)] = []
        for (a, b, c) in faces {
            for (p, q) in [(a, b), (b, c), (c, a)] where seen.insert(key(p, q)).inserted {
                edges.append((p, q))
            }
        }
        self.vertices = vertices
        self.edges = edges
    }
}

/// Organic, blobby displacement of a point on the unit sphere, roughly in -1.8…1.8.
/// Advancing `phase` makes the surface flow.
func orbWobble(_ v: Vec3, phase p: Double) -> Double {
    let a = sin(3.1 * v.x + 1.3 * p) * sin(2.7 * v.y + 1.1 * p + 1.7) * sin(2.3 * v.z + 0.9 * p + 0.6)
    let b = sin(4.3 * v.x + 3.7 * v.y - 1.5 * p) * 0.5
    let c = sin(5.9 * v.z - 2.3 * v.x + 2.1 * p) * 0.3
    return a + b + c
}
