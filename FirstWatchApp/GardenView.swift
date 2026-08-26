import SwiftUI

/// The gamification centrepiece: a plant that grows with cumulative hang time,
/// surrounded by collectable energy orbs (蚂蚁森林-style).
///
/// Fixes applied:
/// - Orbs scattered with seeded randomness (organic), not a rigid ring.
/// - Orb flight vector computed correctly toward the actual tree icon centre.
/// - `collectTarget` passed as the orb→tree vector (not .zero).
/// - "Collect all" placed via VStack/Spacer, no hardcoded padding.
/// - EnergyCollector wired so collected orbs animate out, not pop.
struct GardenView: View {

    @EnvironmentObject private var store: HangSessionStore
    @EnvironmentObject private var energy: EnergyCollector

    /// Tracks the previous stage so we can fire a level-up celebration when the
    /// cumulative total crosses a threshold.
    @State private var previousStage: HangGrowth.Stage?
    /// Spring "nourish" pulse sent to the plant whenever an orb is collected.
    @State private var nourish: Double = 0
    /// Shows a level-up banner briefly on stage change.
    @State private var showLevelUp = false

    private var totalSeconds: Int { HangStats.totalSeconds(store.allSessions) }
    private var stage: HangGrowth.Stage { HangGrowth.stage(forTotalSeconds: totalSeconds) }
    private var toNext: Int? { HangGrowth.secondsToNextStage(total: totalSeconds) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    plantWithOrbs
                    progressToNext
                    forestSection

                    #if DEBUG
                    debugTools
                    #endif
                }
                .padding()
            }
            .navigationTitle("Garden")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: stage) { newStage in
                guard let prev = previousStage, newStage > prev else {
                    previousStage = newStage
                    return
                }
                // Levelled up!
                previousStage = newStage
                celebrateLevelUp()
            }
        }
    }

    /// Fire the level-up celebration: sound + banner + a bigger nourish pulse.
    private func celebrateLevelUp() {
        HangSounds.playLevelUp()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) {
            showLevelUp = true
            nourish = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.4)) { showLevelUp = false }
            withAnimation(.easeOut(duration: 0.5)) { nourish = 0 }
        }
    }

    /// A small nourish pulse (lighter than level-up) when a single orb is fed.
    private func nudgePlant() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { nourish = 1.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.4)) { nourish = 0 }
        }
    }

    // MARK: - Plant + collectable orbs

    /// Orbs not yet collected AND alive (within 72h), capped so the screen
    /// doesn't get crowded. Beyond 72h uncollected orbs wither and vanish
    /// (蚂蚁森林-style FOMO).
    private var visibleOrbs: [HangSession] {
        Array(energy.uncollected(from: store.allSessions).prefix(6))
    }

    private var plantWithOrbs: some View {
        VStack(spacing: 16) {
            // Layered scene (ported concept from Ant Forest's skyLayer /
            // groundLayer / treeLayer / bubblesLayer). The plant + orbs share one
            // coordinate space so fly-vectors land on the plant centre.
            //
            // CRITICAL: the ZStack uses a FIXED frame + `.clipped()` so the orbs'
            // floating/bobbing animations never expand the layout and push the
            // ScrollView around (that was the "whole page jumps" bug). The orbs
            // animate strictly within this box; the page stays still.
            ZStack {
                // sky + ground backdrop (skyLayer + groundLayer).
                sceneBackground
                    .zIndex(0)

                heroPlant
                    .zIndex(1)   // plant (treeLayer)

                ForEach(Array(visibleOrbs.enumerated()), id: \.element.id) { index, session in
                    let pos = orbPosition(for: index, total: visibleOrbs.count, seed: seed(for: session.id))
                    EnergyOrbView(
                        session: session,
                        onCollect: {
                            _ = energy.collect(session)
                            nudgePlant()
                        },
                        floatingOffset: pos,
                        // Fly toward centre (0,0) from the orb's position: vector
                        // is -pos so the orb ends at the plant.
                        collectTarget: CGSize(width: -pos.width, height: -pos.height),
                        phaseSeed: seed(for: session.id)
                    )
                    .zIndex(2)   // orbs (bubblesLayer) above plant so they're tappable
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .clipped()   // orbs float INSIDE this box; page never moves

            if !visibleOrbs.isEmpty {
                Button {
                    let orbs = visibleOrbs
                    for s in orbs { _ = energy.collect(s) }
                    nudgePlant()
                } label: {
                    Label("Collect all (\(visibleOrbs.count))", systemImage: "sparkles")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.neonBlue.opacity(0.2))
                        .foregroundColor(.neonBlue)
                        .cornerRadius(18)
                }
            }
        }
    }

    /// Layered backdrop ported from Ant Forest's skyLayer + groundLayer: a
    /// gradient sky, a drifting cloud, a sun, and rolling ground hills. Gives
    /// the plant a sense of being planted in a real place rather than floating
    /// on a flat card.
    private var sceneBackground: some View {
        ZStack {
            // Sky gradient (day → soft blue).
            LinearGradient(
                gradient: Gradient(colors: [Color(red: 0.74, green: 0.93, blue: 1.0),
                                             Color(red: 0.88, green: 0.98, blue: 0.92)]),
                startPoint: .top,
                endPoint: .bottom
            )

            // Sun (skyLayer.light).
            Circle()
                .fill(Color(red: 1.0, green: 0.92, blue: 0.55).opacity(0.85))
                .frame(width: 46, height: 46)
                .blur(radius: 4)
                .offset(x: 110, y: -78)

            // Drifting cloud (skyLayer.cloundLeft, slow horizontal drift).
            cloudShape
                .offset(x: -60, y: -56)
                .opacity(0.8)

            // Ground mound (groundLayer.ground) — the plant sits on this.
            Ellipse()
                .fill(Color(red: 0.62, green: 0.82, blue: 0.5))
                .frame(width: 240, height: 60)
                .offset(y: 78)

            // Distant hill silhouette (groundLayer.mount).
            Ellipse()
                .fill(Color(red: 0.72, green: 0.88, blue: 0.65).opacity(0.6))
                .frame(width: 320, height: 80)
                .offset(x: 40, y: 96)
        }
        .frame(width: 340, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    /// A simple cloud (three overlapping circles), echoing Ant Forest's
    /// tileset-common-clound.png silhouette.
    private var cloudShape: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.9)).frame(width: 34, height: 34).offset(x: -14, y: 4)
            Circle().fill(Color.white.opacity(0.95)).frame(width: 46, height: 46)
            Circle().fill(Color.white.opacity(0.9)).frame(width: 30, height: 30).offset(x: 18, y: 6)
        }
    }

    /// Deterministic seed in [0,1) from a UUID so each orb's position/phase is
    /// stable across re-renders (no jittering when the list updates).
    private func seed(for id: UUID) -> Double {
        let h = id.hashValue
        return Double(abs(h % 1000)) / 1000.0
    }

    /// Scatter orbs around the plant using seeded angles + radii so they look
    /// organically placed rather than in a rigid ring.
    private func orbPosition(for index: Int, total: Int, seed: Double) -> CGSize {
        guard total > 0 else { return .zero }
        // Spread around the circle, jittered by the per-orb seed.
        let baseAngle = (Double(index) / Double(total)) * 2 * .pi - .pi / 2
        let angle = baseAngle + (seed - 0.5) * 0.6
        let radius: CGFloat = 80 + CGFloat(seed) * 25   // 80–105pt
        return CGSize(width: CGFloat(cos(angle)) * radius,
                      height: CGFloat(sin(angle)) * radius * 0.75)
    }

    // MARK: - Hero plant

    private var heroPlant: some View {
        VStack(spacing: 12) {
            ZStack {
                // The hand-drawn plant, distinct silhouette per stage. `nourish`
                // drives a spring scale/tilt whenever an orb is collected.
                PlantIconView(stage: stage, nourish: nourish, color: stageColor)
                    .accessibilityHidden(true)

                // Level-up celebration banner.
                if showLevelUp {
                    Text("🌱 Grew to \(stage.label)!")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.successGreen.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .offset(y: -86)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            Text(stage.label)
                .font(.title2.bold())

            Text(stage.subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(formatTotal(totalSeconds))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress to next stage

    @ViewBuilder
    private var progressToNext: some View {
        if let toNext = toNext {
            VStack(spacing: 8) {
                Text("\(formatTotal(toNext)) to \(nextStageLabel ?? "max")")
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                ProgressView(value: progressValue)
                    .accentColor(stageColor)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        } else {
            Text("You've reached the top — incredible!")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding()
        }
    }

    private var nextStageLabel: String? {
        let order: [HangGrowth.Stage] = [.seed, .sprout, .sapling, .youngTree, .matureTree, .blossom]
        guard let i = order.firstIndex(of: stage), i + 1 < order.count else { return nil }
        return order[i + 1].label
    }

    private var progressValue: Double {
        guard let toNext = toNext else { return 1 }
        let nextThreshold = totalSeconds + toNext
        let span = Double(nextThreshold - HangGrowth.threshold(for: stage))
        guard span > 0 else { return 1 }
        return 1 - (Double(toNext) / span)
    }

    // MARK: - Forest (one tree per session)

    private var forestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your forest")
                    .font(.headline)
                Spacer()
                Text("\(store.allSessions.count) planted")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if store.allSessions.isEmpty {
                Text("Complete a hang on your watch to plant your first tree.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 16) {
                    ForEach(store.allSessions.reversed()) { session in
                        forestTree(for: session)
                    }
                }
            }
        }
    }

    private func forestTree(for session: HangSession) -> some View {
        // Tree size + hue shift with duration so the forest isn't a wall of
        // identical green dots.
        let scale = min(max(Double(session.totalSeconds) / 60.0, 0.5), 1.6)
        let hue = min(Double(session.totalSeconds) / 120.0, 0.15)
        return VStack(spacing: 4) {
            Image(systemName: "tree.fill")
                .font(.system(size: 32 * scale))
                .foregroundColor(Color(hue: 0.33 - hue, saturation: 0.6, brightness: 0.55))
            Text("\(session.totalSeconds)s")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .accessibilityLabel("Tree from \(session.totalSeconds) second hang")
    }

    // MARK: - Helpers

    private var stageColor: Color {
        switch stage {
        case .seed:       return .energyOrange
        case .sprout:     return .successGreen
        case .sapling:    return .successGreen
        case .youngTree:  return .successGreen
        case .matureTree: return .successGreen
        case .blossom:    return .energyOrange
        }
    }

    private func formatTotal(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    // MARK: - Debug tools (DEBUG builds only)
    #if DEBUG
    private var debugTools: some View {
        VStack(spacing: 8) {
            Text("Demo data")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            ForEach(SeedData.Span.allCases) { span in
                Button {
                    SeedData.load(span: span, into: store)
                } label: {
                    Label("Load \(span.rawValue) sample", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .foregroundColor(.white)
                .background(Color.successGreen)
                .cornerRadius(8)
            }

            Button {
                store.clear()
                energy.reset()
            } label: {
                Label("Clear all data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .foregroundColor(.white)
            .background(Color.dangerRed)
            .cornerRadius(8)
        }
        .padding(.top, 8)
    }
    #endif
}
