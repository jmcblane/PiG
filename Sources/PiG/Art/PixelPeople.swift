import CoreGraphics
import Foundation

/// Procedural 32x52 pixel people in 3/4 view, ported from PiAgents so agents keep their look.
/// Front view faces down-right; back view faces up-right; flip mirrors both.
/// Feet anchor at (16, 48). Seated torso bottom at (16, 38).
enum PixelPeople {
    static let width = 32, height = 52

    struct Options: Hashable {
        var back = false
        var flip = false
        var seated = false
        var frame = 0
    }

    private struct Ramp {
        let o, d2, d, b, l: RGBA
        init(_ hex: String) { self.init(RGBA(hex)) }
        init(_ c: RGBA) {
            o = c.shade(0.38).mix(RGBA("#170c26"), 0.45)
            d2 = c.shade(0.6).mix(RGBA("#2a1f55"), 0.28)
            d = c.shade(0.8).mix(RGBA("#3b2f7a"), 0.15)
            b = c
            l = c.shade(1.08).mix(RGBA("#fff4d6"), 0.28)
        }
        /// Skin: warm shadows. The cool purple ramp reads as stubble on faces.
        init(skin hex: String) {
            let c = RGBA(hex)
            o = c.shade(0.42).mix(RGBA("#2a1010"), 0.4)
            d2 = c.shade(0.68).mix(RGBA("#6b2a22"), 0.2)
            d = c.shade(0.88).mix(RGBA("#b5584a"), 0.12)
            b = c
            l = c.shade(1.06).mix(RGBA("#fff4d6"), 0.22)
        }
    }

    private struct Mask {
        var a = [Bool](repeating: false, count: PixelPeople.width * PixelPeople.height)
        static let W = PixelPeople.width, H = PixelPeople.height

        func has(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < Self.W && y < Self.H && a[y * Self.W + x] }
        mutating func set(_ x: Int, _ y: Int) { if x >= 0 && y >= 0 && x < Self.W && y < Self.H { a[y * Self.W + x] = true } }

        @discardableResult mutating func ell(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Mask {
            for y in 0..<Self.H { for x in 0..<Self.W {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1 { set(x, y) }
            } }
            return self
        }
        @discardableResult mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Mask {
            for y in y0...y1 { for x in x0...x1 { set(x, y) } }
            return self
        }
        @discardableResult mutating func poly(_ pts: [(Double, Double)]) -> Mask {
            for y in 0..<Self.H { for x in 0..<Self.W {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                var inside = false
                var j = pts.count - 1
                for i in 0..<pts.count {
                    let (xi, yi) = pts[i], (xj, yj) = pts[j]
                    if (yi > py) != (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi { inside.toggle() }
                    j = i
                }
                if inside { set(x, y) }
            } }
            return self
        }
        func or(_ m: Mask) -> Mask { var r = self; for i in r.a.indices where m.a[i] { r.a[i] = true }; return r }
        func and(_ m: Mask) -> Mask { var r = self; for i in r.a.indices where !m.a[i] { r.a[i] = false }; return r }
        func keep(_ f: (Int, Int) -> Bool) -> Mask {
            var r = self
            for y in 0..<Self.H { for x in 0..<Self.W where r.a[y * Self.W + x] && !f(x, y) { r.a[y * Self.W + x] = false } }
            return r
        }
        static func e(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Mask { var m = Mask(); m.ell(cx, cy, rx, ry); return m }
        static func r(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Mask { var m = Mask(); m.rect(x0, y0, x1, y1); return m }
        static func p(_ pts: [(Double, Double)]) -> Mask { var m = Mask(); m.poly(pts); return m }
    }

    private enum Shade { case edge, face, sphere(cx: Double, cy: Double, rx: Double, ry: Double) }

    private struct Layer {
        var mask: Mask
        var ramp: Ramp
        var contour = true
        var shade: Shade = .edge
        var force: KeyPath<Ramp, RGBA>?
        var hair = false
    }

    private static func bangY(_ x: Int) -> Int { 12 + ((x * 7) % 3 == 0 ? 1 : 0) }

    private struct HairShape { var front: Mask; var back: Mask?; var bun: Mask?; var earOver = true; var buzz = false }

    private static func hair(_ style: Look.Hair, back: Bool) -> HairShape {
        let top = { Mask.e(15.5, 11.5, 10, 8.2) }
        func fringe(_ x0: Int, _ x1: Int, _ dy: Int = 0) -> (Int, Int) -> Bool { { x, y in !(x >= x0 && x <= x1 && y >= bangY(x) + dy) } }
        if back {
            let cover = top().or(Mask.e(16, 15, 9, 8.5)).keep { x, y in !(x >= 22 && y >= 13) && y <= 21 }
            switch style {
            case .bob: return HairShape(front: cover.or(Mask.r(7, 12, 23, 23)).or(Mask.e(15, 23, 8.5, 2.5)), earOver: false)
            case .long: return HairShape(front: cover.or(Mask.r(8, 12, 23, 31)).or(Mask.e(15.5, 31, 7.5, 3)), earOver: false)
            case .ponytail: return HairShape(front: cover, bun: Mask.r(14, 18, 17, 29).or(Mask.e(15.5, 29.5, 2.5, 2)))
            case .bun: return HairShape(front: cover, bun: Mask.e(16, 4, 4.2, 3.6))
            case .curly:
                var m = cover
                for (a, b) in [(8.0, 12.0), (9, 7.5), (13, 5), (17, 4.5), (21, 5.5), (24, 9), (24.5, 13), (8, 17), (12, 19), (17, 20), (21, 18)] { m.ell(a, b, 4.2, 4) }
                return HairShape(front: m.keep { x, y in !(x >= 23 && y >= 14) })
            case .spiky: return HairShape(front: cover.or(Mask.p([(9, 6), (10, 0), (13, 4), (15, -1), (18, 4), (21, 0), (22, 6)])))
            case .buzz: return HairShape(front: cover.keep { _, y in y <= 19 }, buzz: true)
            case .short: return HairShape(front: cover)
            }
        }
        switch style {
        case .bob, .long:
            let long = style == .long
            let front = Mask.e(15.5, 12.5, 10.5, 9.5).or(Mask.r(6, 12, 12, long ? 26 : 23)).or(Mask.r(23, 12, 25, long ? 24 : 21)).keep(fringe(13, 22))
            let backHair = long ? Mask.r(6, 20, 13, 34).or(Mask.e(9.5, 34, 3.5, 2)).or(Mask.r(22, 22, 25, 31)) : nil
            return HairShape(front: front, back: backHair, earOver: false)
        case .curly:
            var m = Mask()
            for (a, b, r) in [(8.0, 12.0, 4.0), (8.5, 7.5, 4), (12, 5, 4.2), (16, 4, 4.2), (20, 4.5, 4.2), (23.5, 7.5, 4), (25, 11.5, 3.2), (7, 16.5, 3.4)] { m.ell(a, b, r, r) }
            return HairShape(front: m.keep(fringe(12, 24, -1)))
        default:
            var front = top().keep { x, y in fringe(12, 24)(x, y) && y <= 18 && !(x <= 12 && y > 17) }
            var shape = HairShape(front: front)
            if style == .spiky { front = front.or(Mask.p([(8, 7), (9, 1), (12, 5), (14, 0), (17, 4), (20, 0), (21, 5), (24, 2), (24, 9)])) }
            if style == .bun { shape.bun = Mask.e(11.5, 4, 4.2, 3.6) }
            if style == .ponytail { shape.back = Mask.p([(9, 12), (11.5, 14.5), (10, 23), (7.5, 27.5), (5.5, 24), (6, 16)]) }
            if style == .buzz { front = front.keep { x, y in y <= 8 || x <= 11 }; shape.buzz = true }
            shape.front = front
            return shape
        }
    }

    static func canvas(_ L: Look, _ opt: Options) -> PixelCanvas {
        let W = width, H = height
        let back = opt.back, seated = opt.seated, walk = opt.frame == 1, typing = opt.frame == 1
        let front = !back && !seated
        let skin = Ramp(skin: L.skin), shirt = Ramp(L.shirt), pants = Ramp(L.pants), shoes = Ramp(L.shoes)
        let tie = Ramp(L.tie ?? "#c0392b"), white = Ramp("#f2efe8")
        let hs = hair(L.hairStyle, back: back)
        let hairRamp = hs.buzz ? Ramp(RGBA(L.hair).mix(RGBA(L.skin), 0.35)) : Ramp(L.hair)
        var layers: [Layer] = []
        func add(_ m: Mask, _ r: Ramp, contour: Bool = true, shade: Shade = .edge, force: KeyPath<Ramp, RGBA>? = nil, hair: Bool = false) {
            layers.append(Layer(mask: m, ramp: r, contour: contour, shade: shade, force: force, hair: hair))
        }
        let head = Mask.e(16, 14, 9, 9).or(Mask.e(18, 18.5, 7, 5.5))

        if let b = hs.back { add(b, hairRamp, shade: .sphere(cx: 10, cy: 22, rx: 8, ry: 14)) }
        // far arm (behind torso)
        if seated { add(Mask.p([(9, 27), (12, 27), (12, 34), (9, 34)]), shirt, force: \.d) }
        else if front { add(Mask.p([(21, 27), (24, 27.5), (25, 36), (22, 36)]), shirt, force: \.d); add(Mask.e(23.5, 37, 2, 2), skin, force: \.d) }
        else { add(Mask.p([(9, 27), (12, 27), (11, 36), (8, 36)]), shirt, force: \.d); add(Mask.e(9.5, 37, 2, 2), skin, force: \.d) }
        // legs + shoes
        if !seated {
            var p = Mask.r(11, 36, 22, 40), s = Mask()
            if front {
                if walk { p = p.or(Mask.r(10, 40, 14, 47)).or(Mask.r(18, 40, 22, 44)); s.rect(9, 47, 15, 49); s.rect(18, 44, 23, 46) }
                else { p = p.or(Mask.r(11, 40, 15, 46)).or(Mask.r(17, 40, 21, 45)); s.rect(10, 46, 16, 48); s.rect(17, 45, 22, 47); s.rect(23, 46, 23, 47) }
            } else {
                if walk { p = p.or(Mask.r(10, 40, 14, 45)).or(Mask.r(18, 40, 22, 46)); s.rect(9, 44, 14, 46); s.rect(17, 46, 22, 48) }
                else { p = p.or(Mask.r(11, 40, 15, 46)).or(Mask.r(17, 40, 21, 46)); s.rect(10, 45, 15, 47); s.rect(16, 46, 22, 48) }
            }
            add(p, pants)
            add(s, shoes)
        }
        // neck, torso, hood
        add(Mask.r(15, 22, 19, 26), skin, contour: false, force: \.d)
        add(Mask.p([(9, 27.5), (11, 25), (22, 25), (24, 27.5), (23, 38.5), (10, 38.5)]), shirt, shade: .sphere(cx: 13, cy: 27, rx: 13, ry: 14))
        if L.top == .hoodie { add(back ? Mask.e(16, 27, 7, 3.6) : Mask.e(13, 25.5, 5.5, 2.4), shirt, force: \.d) }
        // head, beard, hair, ear
        add(head, skin, shade: .face)
        if L.accessory == .beard && !back {
            add(Mask.e(19, 20.5, 6.8, 4).and(head).keep { _, y in y >= 18 }, hairRamp, shade: .sphere(cx: 16, cy: 18, rx: 9, ry: 6))
        }
        if let bun = hs.bun { add(bun, hairRamp, shade: .sphere(cx: 11, cy: 2, rx: 6, ry: 6)) }
        add(hs.front, hairRamp, shade: .sphere(cx: 13, cy: 8, rx: 12, ry: 12), hair: true)
        if hs.earOver { add(back ? Mask.e(21.5, 15.5, 1.8, 2.6) : Mask.e(11, 15.5, 1.9, 2.7), skin, force: \.b) }
        // near arm + hand
        if seated {
            let t = typing ? 1.0 : 0
            add(Mask.p([(21, 26), (25, 27), (26, 31), (29, 32 + t), (28.5, 35 + t), (24, 33), (21.5, 30)]), shirt)
            add(Mask.e(29.3, 34 + t, 2, 1.8), skin)
        } else if front {
            add(Mask.p([(8, 27.5), (12, 26), (11.4, 36), (7.7, 36)]), shirt)
            add(Mask.e(9.6, 37.3, 2.2, 2), skin)
        } else {
            add(Mask.p([(21, 26), (25, 27.5), (25.3, 36), (21.7, 36)]), shirt)
            add(Mask.e(23.5, 37.3, 2.2, 2), skin)
        }

        // compose
        var own = [Int](repeating: -1, count: W * H)
        for (i, ly) in layers.enumerated() { for p in 0..<(W * H) where ly.mask.a[p] { own[p] = i } }
        func O(_ x: Int, _ y: Int) -> Int { (x < 0 || y < 0 || x >= W || y >= H) ? -1 : own[y * W + x] }
        var col = [RGBA?](repeating: nil, count: W * H)
        for y in 0..<H { for x in 0..<W {
            let i = O(x, y); guard i >= 0 else { continue }
            let ly = layers[i], r = ly.ramp
            let inM = { (a: Int, b: Int) in ly.mask.has(a, b) }
            var c = r.b
            if let f = ly.force { c = r[keyPath: f] }
            else {
                switch ly.shade {
                case .sphere(let cx, let cy, let rx, let ry):
                    let nx = (Double(x) + 0.5 - cx) / rx, ny = (Double(y) + 0.5 - cy) / ry, v = nx * 0.62 + ny * 0.78
                    if v > 0.72 { c = r.d } else if v < -0.2 { c = r.l }
                    if !inM(x + 1, y) || !inM(x, y + 1) { c = r.d }
                    else if (!inM(x - 1, y) || !inM(x, y - 1)) && v < 0.3 { c = r.l }
                    if ly.hair { let d = (nx * nx + ny * ny).squareRoot(); if d > 0.38 && d < 0.52 && nx < 0.1 && ny < -0.05 { c = r.l } }
                case .edge:
                    if !inM(x + 1, y) || !inM(x, y + 1) { c = r.d } else if !inM(x - 1, y) || !inM(x, y - 1) { c = r.l }
                case .face:
                    // Shade only the turned-away cheek; leave the chin and jaw clean.
                    if !inM(x + 1, y) { c = r.d } else if (!inM(x - 1, y) || !inM(x, y - 1)) && y < 16 { c = r.l }
                }
                if O(x, y - 1) > i || O(x - 1, y) > i { c = r.d }
            }
            if ly.contour {
                for (a, b) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] { let j = O(a, b); if j >= 0 && j < i { c = r.d2; break } }
            }
            col[y * W + x] = c
        } }
        func put(_ x: Int, _ y: Int, _ c: RGBA) { if x >= 0 && y >= 0 && x < W && y < H { col[y * W + x] = c } }

        // torso details
        if !back {
            if L.top == .collar || L.tie != nil {
                put(16, 25, white.b); put(17, 25, white.b); put(17, 26, white.d); put(20, 25, white.b); put(19, 25, white.b); put(19, 26, white.d); put(18, 25, skin.d)
            } else if L.top == .hoodie {
                for (x, y, c) in [(17, 27, white.d), (17, 28, white.d), (17, 29, white.b), (20, 27, white.d), (20, 28, white.d), (20, 29, white.b)] { put(x, y, c) }
                put(18, 25, skin.d); put(19, 25, skin.d)
            } else {
                for x in 16...20 { put(x, 25, skin.d) }
                put(17, 26, skin.b); put(18, 26, skin.b); put(19, 26, skin.d)
            }
            if L.tie != nil {
                put(18, 26, tie.b); put(18, 27, tie.d)
                for y in 28...34 { put(18, y, tie.b); put(19, y, tie.d) }
                put(18, 35, tie.d)
            }
            if L.top == .collar && L.tie == nil { for y in [29, 32, 35] { put(18, y, shirt.d2) } }
        } else if L.top == .collar || L.tie != nil {
            for x in 13...20 { put(x, 25, white.d) }
        }

        // face
        if !back {
            let eye = RGBA("#2a1a3a")
            for ex in [16, 21] { for y in 14...16 { put(ex, y, eye); put(ex + 1, y, eye) }; put(ex, 14, RGBA(255, 255, 255)) }
            put(20, 17, skin.d)
            let blush = RGBA(L.skin).mix(RGBA("#ff6b81"), 0.38), mouth = RGBA("#7a3036")
            if L.accessory != .beard { put(15, 18, blush); put(16, 18, blush); if hs.earOver { put(22, 18, blush); put(23, 18, blush) } }
            put(19, 19, mouth); put(20, 19, mouth)
            if L.happy { put(18, 18, mouth); put(21, 18, mouth) }
            if L.accessory == .glasses {
                let g = RGBA(L.accentColor).mix(RGBA("#1a1024"), 0.45)
                for (x0, x1) in [(15, 18), (20, 23)] {
                    for x in x0...x1 { put(x, 13, g); put(x, 17, g) }
                    for y in 14...16 { put(x0, y, g); put(x1, y, g) }
                }
                put(19, 14, g); put(14, 14, g); put(13, 14, g)
            }
        }

        // selective outline
        let out = PixelCanvas(width: W, height: H)
        for y in 0..<H { for x in 0..<W {
            let p = y * W + x
            if let c = col[p] { out.set(opt.flip ? W - 1 - x : x, y, c); continue }
            var src = -1, below = false
            if O(x, y - 1) >= 0 { src = O(x, y - 1); below = true }
            else { for (a, b) in [(x - 1, y), (x + 1, y), (x, y + 1)] where O(a, b) >= 0 { src = O(a, b); break } }
            if src >= 0 {
                let o = layers[src].ramp.o
                out.set(opt.flip ? W - 1 - x : x, y, below ? o.mix(RGBA("#0c0612"), 0.35) : o)
            }
        } }
        return out
    }

    private struct CacheKey: Hashable { let look: Look; let options: Options }
    @MainActor private static var cache: [CacheKey: CGImage] = [:]

    /// Rendering walks every pixel, so images are cached per look and pose.
    @MainActor static func image(_ look: Look, _ opt: Options = Options()) -> CGImage {
        let key = CacheKey(look: look, options: opt)
        if let img = cache[key] { return img }
        let img = canvas(look, opt).image()
        cache[key] = img
        return img
    }
}
