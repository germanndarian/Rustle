import Foundation

enum LeafFall: String, CaseIterable {
    case off, light, steady, heavy, variable

    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .steady: return "Steady"
        case .heavy: return "Heavy"
        case .variable: return "Variable"
        }
    }
}

enum Breeze: String, CaseIterable {
    case calm, breezy, gusty

    var title: String { rawValue.capitalized }
}

/// User settings, persisted in UserDefaults.
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let leafFall = "leafFall"
        static let breeze = "breeze"
        static let accumulate = "accumulate"
        static let windClears = "windClears"
        static let leavesOnWindows = "leavesOnWindows"
        static let crunchSound = "crunchSound"
        static let behindWindows = "behindWindows"
        static let showInScreenshots = "showInScreenshots"
    }

    private init() {
        defaults.register(defaults: [
            Key.leafFall: LeafFall.steady.rawValue,
            Key.breeze: Breeze.breezy.rawValue,
            Key.accumulate: true,
            Key.windClears: true,
            Key.leavesOnWindows: true,
            Key.crunchSound: true,
            Key.behindWindows: false,
            Key.showInScreenshots: false,
        ])
    }

    var leafFall: LeafFall {
        get { LeafFall(rawValue: defaults.string(forKey: Key.leafFall) ?? "") ?? .steady }
        set { defaults.set(newValue.rawValue, forKey: Key.leafFall) }
    }

    var breeze: Breeze {
        get { Breeze(rawValue: defaults.string(forKey: Key.breeze) ?? "") ?? .breezy }
        set { defaults.set(newValue.rawValue, forKey: Key.breeze) }
    }

    /// Leaves pile up where they land instead of fading away.
    var accumulate: Bool {
        get { defaults.bool(forKey: Key.accumulate) }
        set { defaults.set(newValue, forKey: Key.accumulate) }
    }

    /// Now and then a gust of wind blows part of the pile off the screen.
    var windClears: Bool {
        get { defaults.bool(forKey: Key.windClears) }
        set { defaults.set(newValue, forKey: Key.windClears) }
    }

    var leavesOnWindows: Bool {
        get { defaults.bool(forKey: Key.leavesOnWindows) }
        set { defaults.set(newValue, forKey: Key.leavesOnWindows) }
    }

    /// Sweeping the cursor through the pile makes a crunching sound.
    var crunchSound: Bool {
        get { defaults.bool(forKey: Key.crunchSound) }
        set { defaults.set(newValue, forKey: Key.crunchSound) }
    }

    var behindWindows: Bool {
        get { defaults.bool(forKey: Key.behindWindows) }
        set { defaults.set(newValue, forKey: Key.behindWindows) }
    }

    var showInScreenshots: Bool {
        get { defaults.bool(forKey: Key.showInScreenshots) }
        set { defaults.set(newValue, forKey: Key.showInScreenshots) }
    }
}
