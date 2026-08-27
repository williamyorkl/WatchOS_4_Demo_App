import Foundation

/// Gamification growth model: cumulative hang time grows a plant through stages.
///
/// Pure, testable, shared by the phone's Garden view (and potentially the watch
/// complication later). The stage thresholds are deliberately generous so the
/// journey from seed → tree takes real, sustained effort — mirroring how Forest
/// rewards consistency. Stages only go UP (no "tree dies" punishment): this is a
/// habit-building app, and positive reinforcement beats penalties for exercise.
enum HangGrowth {

    /// Visual + label stage for the user's plant, derived from total seconds.
    enum Stage: Int, Comparable, CaseIterable {
        case seed = 0
        case sprout
        case sapling
        case youngTree
        case matureTree
        case blossom

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// SF Symbol icon for this stage. Drawn from SF Symbols so no asset work
        /// is required (razor's principle).
        var iconName: String {
            switch self {
            case .seed:       return "circle.fill"           // a seed dot
            case .sprout:     return "leaf.fill"
            case .sapling:    return "leaf.arrow.triangle.circlepath"
            case .youngTree:  return "tree.fill"
            case .matureTree: return "tropicalstorm"         // big leafy crown stand-in
            case .blossom:    return "flame.fill"            // flowering highlight
            }
        }

        /// Human label shown under the plant.
        var label: String {
            switch self {
            case .seed:       return "Seed"
            case .sprout:     return "Sprout"
            case .sapling:    return "Sapling"
            case .youngTree:  return "Young Tree"
            case .matureTree: return "Mighty Tree"
            case .blossom:    return "Blossom"
            }
        }

        /// Encouraging one-liner describing the stage.
        var subtitle: String {
            switch self {
            case .seed:       return "Every hang starts here."
            case .sprout:     return "You've taken root!"
            case .sapling:    return "Growing stronger each day."
            case .youngTree:  return "Branching out."
            case .matureTree: return "A force of nature."
            case .blossom:    return "In full bloom. Remarkable."
            }
        }
    }

    /// Cumulative-seconds thresholds for each stage above `seed`.
    /// Index N corresponds to `Stage.allCases[N+1]` (seed is always 0s).
    /// Tunable in one place; tests pin the exact boundaries.
    static let thresholds: [Int] = [60, 300, 900, 1800, 3600]
    //                    sprout sapling youngTree mature blossom
    //                     1min  5min   15min    30min  60min

    /// The stage for a given cumulative total (seconds).
    static func stage(forTotalSeconds total: Int) -> Stage {
        var current: Stage = .seed
        for (index, threshold) in thresholds.enumerated() {
            if total >= threshold, let next = Stage(rawValue: index + 1) {
                current = next
            } else {
                break
            }
        }
        return current
    }

    /// Seconds still needed to reach the next stage. `nil` if already at the
    /// top stage.
    static func secondsToNextStage(total: Int) -> Int? {
        let current = stage(forTotalSeconds: total)
        guard let nextIndex = thresholds.indices.first(where: { thresholds[$0] > total }) else {
            return nil // at the top
        }
        return thresholds[nextIndex] - total
    }

    /// The threshold (in seconds) that defines the START of a given stage.
    /// Seed starts at 0.
    static func threshold(for stage: Stage) -> Int {
        guard stage != .seed else { return 0 }
        let index = stage.rawValue - 1
        return thresholds[index]
    }
}
