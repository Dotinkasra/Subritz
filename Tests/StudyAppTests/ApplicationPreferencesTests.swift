import Foundation
import Testing

@testable import StudyApp
@testable import StudyCore

struct ApplicationPreferencesTests {
  @Test func comparisonInheritsSettingsWithoutWritingIntoTheOriginalDomain() throws {
    let sourceName = "Subritz.Tests.Source." + UUID().uuidString
    let targetName = "Subritz.Tests.Comparison." + UUID().uuidString
    let source = try #require(UserDefaults(suiteName: sourceName))
    let target = try #require(UserDefaults(suiteName: targetName))
    defer {
      source.removePersistentDomain(forName: sourceName)
      target.removePersistentDomain(forName: targetName)
    }
    var original = AppSettings()
    original.dictionary = "eijiro"
    original.advancedMode = true
    original.aiGrammarEnabled = false
    original.save(defaults: source)
    ApplicationPreferences.inheritSettings(from: sourceName, into: target)
    #expect(AppSettings.load(defaults: target) == original)
    var changed = original
    changed.advancedMode = false
    changed.save(defaults: target)
    #expect(AppSettings.load(defaults: source) == original)
    ApplicationPreferences.inheritSettings(from: sourceName, into: target)
    #expect(AppSettings.load(defaults: target) == changed)
  }
}
