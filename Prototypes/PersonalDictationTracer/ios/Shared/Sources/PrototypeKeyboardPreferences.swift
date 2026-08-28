import Foundation

enum PrototypeKeyboardPreferences {
    static let swipeToTypeKey = "prototype.keyboard.swipe-to-type"
    static let swipeToTypeDefault = false

    static func isSwipeToTypeEnabled(
        in defaults: UserDefaults? = UserDefaults(suiteName: PrototypeMailbox.appGroupID)
    ) -> Bool {
        guard let defaults,
              defaults.object(forKey: swipeToTypeKey) != nil else {
            return swipeToTypeDefault
        }
        return defaults.bool(forKey: swipeToTypeKey)
    }

    static func setSwipeToTypeEnabled(
        _ isEnabled: Bool,
        in defaults: UserDefaults? = UserDefaults(suiteName: PrototypeMailbox.appGroupID)
    ) {
        defaults?.set(isEnabled, forKey: swipeToTypeKey)
    }
}
