import Foundation

enum ApplicationPreferences {
  // A separately identified comparison bundle can inherit the original settings
  // without saving future preference changes back into the running original app.
  static func defaults(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> UserDefaults {
    if let domain = bundle.object(forInfoDictionaryKey: "SubritzSettingsSourceDomain") as? String {
      inheritSettings(from: domain, into: defaults)
    }
    return defaults
  }
  static func inheritSettings(from domain: String, into defaults: UserDefaults) {
    guard defaults.data(forKey: "settings") == nil,
      let settings = defaults.persistentDomain(forName: domain)?["settings"] as? Data
    else { return }
    defaults.register(defaults: ["settings": settings])
  }
}
