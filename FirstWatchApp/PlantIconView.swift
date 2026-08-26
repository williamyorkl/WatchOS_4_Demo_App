import SwiftUI

/// A high-quality, hand-drawn tree rendered with Bézier `Path`s.
///
/// Why Path (not Lottie / Canvas / images):
/// - Lottie needs an SPM dependency the user must add in Xcode (can't be done
///   via text editing). Tracked as a follow-up.
/// - `Canvas` requires iOS 15; we target iOS 14.
/// - `Path` + `Shape` + `drawingGroup()` are iOS 14, dependency-free, and with
///   real Bézier curves produce organic, non-circular foliage that actually
///   reads as a tree.
///
/// Each growth stage scales the SAME tree up and adds detail (more foliage
/// blobs, deeper trunk, a blossom), so it feels like one plant growing rather
/// than six unrelated clip-art icons. `sway` drives a gentle wind loop; `nourish`
/// is a brief spring scale-up when an orb is collected.
struct PlantIconView: View {

    let stage: HangGrowth.Stage
    var nourish: Double = 0
    var color: Color = .successGreen

    @State private var swayPhase: Double = 0   // wind loop phase

    var body: some View {
        tree(scale: growthScale, windTilt: sin(swiftPhase()) * 2.5, nourishAmount: nourish)
            .frame(width: 200, height: 240)
            .onAppear { startWind() }
    }

    /// Drive a gentle wind via a repeating animation on the phase (iOS 14-safe,
    /// TimelineView would need iOS 15).
    private func startWind() {
        withAnimation(.linear(duration: 3.14).repeatForever(autoreverses: true)) {
            swayPhase = .pi
        }
    }

    private func swiftPhase() -> Double { swayPhase }

    /// Overall size multiplier per stage: seed tiny → blossom large.
    private var growthScale: CGFloat {
        switch stage {
        case .seed:       return 0.35
        case .sprout:     return 0.62
        case .sapling:    return 0.82
        case .youngTree:  return 1.0
        case .matureTree: return 1.15
        case .blossom:    return 1.22
        }
    }

    // MARK: - Tree composition

    @ViewBuilder
    private func tree(scale: CGFloat, windTilt: Double, nourishAmount: Double) -> some View {
        let totalScale = scale * (1.0 + CGFloat(nourishAmount) * 0.06)
        // Fixed canvas. Origin = top-left, y grows DOWNWARD (standard SwiftUI).
        // Ground line is at the BOTTOM of the canvas. Everything is laid out in
        // this one coordinate space, then scaled + tilted together.
        let canvasH: CGFloat = 220
        let groundY = canvasH - 16   // soil sits here

        ZStack {
            // Ground shadow.
            Ellipse()
                .fill(Color.black.opacity(0.15))
                .frame(width: 130, height: 22)
                .offset(y: groundY + 6)

            // Soil mound.
            Ellipse()
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.29, blue: 0.17),
                                                Color(red: 0.32, green: 0.19, blue: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 120, height: 28)
                .offset(y: groundY)

            if stage == .seed {
                // Seed sits just at the soil line.
                seedShape.offset(y: groundY - 4)
            } else {
                let h = trunkHeight(for: stage)
                let canopyBaseY = groundY - h   // top of the trunk
                // Trunk: drawn from groundY UPWARD to (groundY - h).
                trunkShape(stage: stage, baseY: groundY, height: h)
                // Canopy: centred at the trunk's top.
                canopy(stage: stage, color: color)
                    .offset(y: canopyBaseY)
            }
        }
        .frame(width: 220, height: canvasH)
        .scaleEffect(totalScale, anchor: UnitPoint(x: 0.5, y: 1.0))
        .rotationEffect(.degrees(windTilt), anchor: UnitPoint(x: 0.5, y: 1.0))
        .shadow(color: color.opacity(0.2), radius: 8, y: 5)
    }

    /// Trunk height per stage.
    private func trunkHeight(for stage: HangGrowth.Stage) -> CGFloat {
        switch stage {
        case .seed: return 0
        case .sprout: return 42
        case .sapling: return 62
        case .youngTree: return 80
        case .matureTree: return 96
        case .blossom: return 100
        }
    }

    // MARK: - Trunk + canopy (unified coordinate system)
    //
    // Both sit in the SAME ZStack whose origin (0,0) is the ground line at the
    // trunk base. Trunk grows UPWARD (negative y); canopy is offset by the trunk
    // height so it caps the top. This fixes the old bug where foliage's offset
    // and trunk's frame used mismatched origins, leaving the canopy floating
    // detached from the trunk.

    private var seedShape: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: -16))
                p.addQuadCurve(to: CGPoint(x: 0, y: 16), control: CGPoint(x: 14, y: 0))
                p.addQuadCurve(to: CGPoint(x: 0, y: -16), control: CGPoint(x: -14, y: 0))
            }
            .fill(LinearGradient(colors: [Color(red: 0.7, green: 0.5, blue: 0.25),
                                           Color(red: 0.5, green: 0.32, blue: 0.15)],
                                  startPoint: .top, endPoint: .bottom))
            .frame(width: 30, height: 34)
            Path { p in
                p.move(to: CGPoint(x: -8, y: -2))
                p.addQuadCurve(to: CGPoint(x: 8, y: 2), control: CGPoint(x: 0, y: 6))
            }
            .stroke(Color(red: 0.35, green: 0.22, blue: 0.1).opacity(0.5), lineWidth: 1.5)
            .frame(width: 30, height: 34)
        }
    }

    /// Trunk drawn in the canvas coordinate space (y grows down).
    /// `baseY` is the ground line (bottom of trunk); trunk extends UP from
    /// baseY to (baseY - height). All points use canvas coordinates.
    private func trunkShape(stage: HangGrowth.Stage, baseY: CGFloat, height: CGFloat) -> some View {
        let baseWidth: CGFloat = stage == .sprout ? 10 : (stage == .sapling ? 13 : 18)
        let topWidth = baseWidth * 0.5
        let topY = baseY - height

        return Path { p in
            p.move(to: CGPoint(x: -baseWidth / 2, y: baseY))
            p.addQuadCurve(to: CGPoint(x: -topWidth / 2, y: topY),
                           control: CGPoint(x: -baseWidth / 2 - 3, y: baseY - height * 0.55))
            p.addLine(to: CGPoint(x: topWidth / 2, y: topY))
            p.addQuadCurve(to: CGPoint(x: baseWidth / 2, y: baseY),
                           control: CGPoint(x: baseWidth / 2 + 3, y: baseY - height * 0.55))
            p.closeSubpath()
        }
        .fill(LinearGradient(colors: [Color(red: 0.58, green: 0.37, blue: 0.21),
                                       Color(red: 0.40, green: 0.24, blue: 0.14),
                                       Color(red: 0.58, green: 0.37, blue: 0.21)],
                             startPoint: .leading, endPoint: .trailing))
        .overlay(
            Path { p in
                let gy = baseY - height * 0.15
                let ty = baseY - height * 0.8
                p.move(to: CGPoint(x: -3, y: ty))
                p.addQuadCurve(to: CGPoint(x: -1, y: gy),
                               control: CGPoint(x: -5, y: baseY - height * 0.5))
            }
            .stroke(Color(red: 0.26, green: 0.15, blue: 0.07).opacity(0.5), lineWidth: 1.2)
        )
    }

    /// Canopy (foliage blobs) positioned at the TOP of the trunk.
    /// Offset is applied by the caller via `trunkHeight`.
    private func canopy(stage: HangGrowth.Stage, color: Color) -> some View {
        let blobs = foliageBlobs(stage: stage)

        return ZStack {
            ForEach(blobs.indices, id: \.self) { i in
                let b = blobs[i]
                BlobShape()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [lighten(color, by: b.light),
                                                         color,
                                                         darken(color, by: 0.20)]),
                            center: UnitPoint(x: 0.35, y: 0.3),
                            startRadius: b.size * 0.1,
                            endRadius: b.size * 0.55
                        )
                    )
                    .frame(width: b.size, height: b.size)
                    .offset(x: b.offset.width, y: b.offset.height)
            }

            if stage == .blossom {
                ForEach(blossomPositions, id: \.self) { pos in
                    Circle().fill(Color(red: 1.0, green: 0.75, blue: 0.85))
                        .frame(width: 9, height: 9).offset(x: pos.x, y: pos.y)
                    Circle().fill(Color.white)
                        .frame(width: 3, height: 3).offset(x: pos.x, y: pos.y)
                }
            }
        }
    }

    private struct FoliageBlob {
        let size: CGFloat
        let offset: CGSize
        let light: Double
    }

    private func foliageBlobs(stage: HangGrowth.Stage) -> [FoliageBlob] {
        switch stage {
        case .seed: return []
        case .sprout:
            return [FoliageBlob(size: 30, offset: CGSize(width: -14, height: 0), light: 0.22),
                    FoliageBlob(size: 30, offset: CGSize(width: 14, height: 0), light: 0.22)]
        case .sapling:
            return [FoliageBlob(size: 50, offset: CGSize(width: 0, height: 0), light: 0.16),
                    FoliageBlob(size: 38, offset: CGSize(width: -26, height: 10), light: 0.26),
                    FoliageBlob(size: 38, offset: CGSize(width: 26, height: 10), light: 0.26)]
        case .youngTree:
            return [FoliageBlob(size: 72, offset: CGSize(width: 0, height: 0), light: 0.13),
                    FoliageBlob(size: 54, offset: CGSize(width: -34, height: 12), light: 0.23),
                    FoliageBlob(size: 54, offset: CGSize(width: 34, height: 12), light: 0.23),
                    FoliageBlob(size: 44, offset: CGSize(width: 0, height: -26), light: 0.30)]
        case .matureTree, .blossom:
            return [FoliageBlob(size: 92, offset: CGSize(width: 0, height: 8), light: 0.10),
                    FoliageBlob(size: 70, offset: CGSize(width: -42, height: 16), light: 0.20),
                    FoliageBlob(size: 70, offset: CGSize(width: 42, height: 16), light: 0.20),
                    FoliageBlob(size: 60, offset: CGSize(width: -20, height: -24), light: 0.27),
                    FoliageBlob(size: 60, offset: CGSize(width: 22, height: -28), light: 0.27),
                    FoliageBlob(size: 52, offset: CGSize(width: 0, height: -46), light: 0.32)]
        }
    }

    private struct BlossomSpot: Hashable { let x: CGFloat; let y: CGFloat }

    private var blossomPositions: [BlossomSpot] {
        [BlossomSpot(x: -34, y: -10), BlossomSpot(x: 30, y: -16),
         BlossomSpot(x: -8, y: -36), BlossomSpot(x: 38, y: 4),
         BlossomSpot(x: -40, y: 8), BlossomSpot(x: 6, y: -24),
         BlossomSpot(x: 14, y: 14)]
    }

    // MARK: - Colour helpers

    private func lighten(_ c: Color, by amount: Double) -> Color {
        UIColor(c).lighten(by: amount).toColor()
    }
    private func darken(_ c: Color, by amount: Double) -> Color {
        UIColor(c).darken(by: amount).toColor()
    }
}

// MARK: - Organic blob shape

/// An irregular rounded blob (a circle perturbed by alternating arc radii) so
/// foliage reads as organic, not as stacked circles.
struct BlobShape: Shape {
    var irregularity: CGFloat = 0.18

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 12
        var firstPoint: CGPoint?
        for i in 0..<steps {
            let angle = (Double(i) / Double(steps)) * 2 * .pi
            // Alternate radius slightly to create lobes.
            let lobe = (i % 2 == 0) ? (1 + irregularity) : (1 - irregularity * 0.6)
            let radius = r * CGFloat(lobe)
            let pt = CGPoint(x: cx + CGFloat(cos(angle)) * radius,
                             y: cy + CGFloat(sin(angle)) * radius)
            if i == 0 { firstPoint = pt; path.move(to: pt) }
            else { path.addLine(to: pt) }
        }
        if let fp = firstPoint { path.closeSubpath() }
        return path
    }
}

// MARK: - UIColor brightness helpers

private extension UIColor {
    func lighten(by amount: Double) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: max(s - CGFloat(amount) * 0.3, 0),
                           brightness: min(b + CGFloat(amount), 1), alpha: a)
        }
        return self
    }
    func darken(by amount: Double) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s,
                           brightness: max(b - CGFloat(amount), 0), alpha: a)
        }
        return self
    }
    func toColor() -> Color { Color(self) }
}
