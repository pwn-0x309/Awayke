//
//  AutoOffPolicy.swift
//  Awayke
//
//  Pure decision logic for battery-based auto-off. No IOKit, no side
//  effects — given the current state it returns the action to take.
//

enum AutoOffAction: Equatable {
    case none
    case suspend
    case resume
}

enum AutoOffPolicy {
    /// - Parameters:
    ///   - intent: the user wants Awayke on.
    ///   - suspended: battery auto-off is currently holding Awayke off.
    ///   - percent: current battery charge, 0...100.
    ///   - onAC: running on AC / external power.
    ///   - threshold: 0 disables the feature; otherwise the low-battery floor.
    ///   - hysteresis: extra points above threshold required to resume.
    static func decide(intent: Bool,
                       suspended: Bool,
                       percent: Int,
                       onAC: Bool,
                       threshold: Int,
                       hysteresis: Int = 5) -> AutoOffAction {
        guard threshold > 0 else { return .none }

        if !suspended, intent, !onAC, percent < threshold {
            return .suspend
        }
        if suspended, onAC, percent >= threshold + hysteresis {
            return .resume
        }
        return .none
    }
}
