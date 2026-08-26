import SwiftUI
import UIKit

/// A floating energy orb using the REAL Ant Forest bubble sprite (cropped from
/// the open-source repo's tileset-bubble.png), plus the real ripple sprite.
///
/// This replaces the hand-drawn circles — the official sprite has proper water-
/// drop shape, inner gradient, highlight, and border that hand-drawing couldn't
/// match. Animation timings still follow Ant Forest's home.js parameters:
///   - fly-to-tree: MoveTo(600ms) + FadeOut(600ms) + ScaleTo(0,0)
///   - number float: MoveBy(1000ms, y:-80) Quartic.Out + FadeOut(1200ms)
///   - ripple: 3 rings staggered 110ms, ScaleTo(1.4) + FadeOut(1000ms)
struct EnergyOrbView: View {

    let session: HangSession
    let onCollect: () -> Void

    var floatingOffset: CGSize = .zero
    var collectTarget: CGSize = .zero
    var phaseSeed: Double = 0

    @State private var isCollected = false
    @State private var flyOffset: CGSize = .zero
    @State private var opacity: Double = 1
    @State private var bobbing = false
    @State private var showRipples = false
    @State private var floaterProgress: CGFloat = 0
    @State private var pulse: Double = 1.0   // gentle ambient pulse (bling)

    /// Orb display size (logical points). The sprite is scaled to this.
    private var orbSize: CGFloat {
        CGFloat(min(max(session.totalSeconds / 10, 44), 80))
    }

    var body: some View {
        ZStack {
            // Real ripple sprite from Ant Forest, 3 staggered rings.
            rippleRings

            ZStack {
                orbSprite
                floatingNumber
            }
        }
        .offset(x: floatingOffset.width + flyOffset.width,
                y: floatingOffset.height + flyOffset.height + bobOffset)
        .opacity(opacity)
        .scaleEffect(isCollected ? 0.01 : pulse)
        .contentShape(Circle().inset(by: -10))
        .onTapGesture { handleTap() }
        .onAppear {
            // Gentle floating bob.
            withAnimation(.easeInOut(duration: 2.0 + phaseSeed * 0.6)
                            .repeatForever(autoreverses: true).delay(phaseSeed * 0.4)) {
                bobbing = true
            }
            // Ambient pulse (the orb "breathes" slightly so it feels alive).
            withAnimation(.easeInOut(duration: 1.6 + phaseSeed)
                            .repeatForever(autoreverses: true)) {
                pulse = 1.06
            }
        }
    }

    // MARK: - Real sprite orb

    /// The official Ant Forest bubble-full sprite. Overlaid with the energy
    /// number (the original shows the gram value centred).
    private var orbSprite: some View {
        ZStack {
            Image("EnergyOrb")
                .resizable()
                .interpolation(.medium)
                .frame(width: orbSize, height: orbSize)
                // Warm outer glow to make it pop against any background.
                .shadow(color: Color(red: 1.0, green: 0.75, blue: 0.25).opacity(0.55),
                        radius: 8, y: 3)

            Text("\(session.totalSeconds)")
                .font(.system(size: orbSize * 0.30, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
                .allowsHitTesting(false)
        }
    }

    /// "+Xs" floating number on collect. Rises 80pt, Quartic.Out, fades 1200ms.
    @ViewBuilder
    private var floatingNumber: some View {
        if isCollected {
            Text("+\(session.totalSeconds)s")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.successGreen))
                .shadow(color: .black.opacity(0.25), radius: 2)
                .offset(y: -80 * floaterProgress)
                .opacity(Double(1 - floaterProgress))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Real ripple sprite rings

    /// Three ripple sprites staggered ~110ms, scaling to 1.4 and fading —
    /// ported from Ant Forest ripple(), using the real ripple.png.
    private var rippleRings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Image("Ripple")
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: orbSize, height: orbSize)
                    .scaleEffect(showRipples ? 1.4 : 0.6)
                    .opacity(showRipples ? 0 : 0.85)
                    .animation(.easeOut(duration: 1.0).delay(Double(i) * 0.11),
                               value: showRipples)
            }
        }
    }

    private var bobOffset: CGFloat {
        bobbing ? CGFloat(-7 - phaseSeed * 3) : 0
    }

    // MARK: - Collect sequence (Ant Forest timings)

    private func handleTap() {
        guard !isCollected else { return }
        isCollected = true

        HangSounds.playCollect()
        triggerHaptic()

        showRipples = true
        withAnimation(.easeOut(duration: 1.0)) { floaterProgress = 1.0 }   // Quartic.Out
        withAnimation(.easeIn(duration: 0.6)) {                            // 600ms fly
            flyOffset = collectTarget
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onCollect() }
    }

    private func triggerHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred(intensity: 0.7)
    }
}
