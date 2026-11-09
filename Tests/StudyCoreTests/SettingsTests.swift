import Foundation
import Testing

@testable import StudyCore

struct SettingsTests {
  @Test func legacyModelMigratesOnlyToItsProvider() throws {
    for provider in ["local", "codex"] {
      let data = Data(
        "{\"provider\":\"\(provider)\",\"model\":\"legacy-model\",\"cacheMB\":512}".utf8)
      var settings = try JSONDecoder().decode(AppSettings.self, from: data)
      #expect(settings.model == "legacy-model")
      #expect(settings.cacheMB == 512)
      settings.provider = provider == "local" ? "codex" : "local"
      #expect(settings.model.isEmpty)
      #expect(settings.timeout == 120)
      #expect(settings.aiGrammarEnabled)
      #expect(!settings.advancedMode)
      #expect(settings.dictionaryBrowser == "system")
      #expect(settings.realtimePronunciationEnabled)
      #expect(settings.wordSpeechQuality == .standard)
      #expect(settings.subtitleRowSpacing == 1 && settings.liveSubtitleRowSpacing == 1)
    }
  }
  @Test func providerModelsAndCachePathRoundTripSeparately() throws {
    var settings = AppSettings()
    settings.localModel = "Local-Model"
    settings.codexModel = " GPT-6-Luna "
    settings.cacheDirectory = "/tmp/Subritz Cache"
    settings.aiGrammarEnabled = false
    settings.advancedMode = true
    settings.realtimePronunciationEnabled = false
    settings.wordSpeechQuality = .premium
    settings.dictionaryBrowser = "browser:com.apple.Safari"
    settings.subtitleRowSpacing = 0.75
    settings.liveSubtitleRowSpacing = 0.2
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    #expect(decoded.grammarModel == "Local-Model")
    var codex = decoded
    codex.provider = "codex"
    #expect(codex.grammarModel == "gpt-6-luna")
    #expect(codex.cacheURL.path == "/tmp/Subritz Cache")
    #expect(AppSettings().cacheURL == AppSettings.defaultCacheURL)
  }
  @Test func subtitleSpacingPreferencesStayWithinReadableSliderRange() throws {
    let decoded = try JSONDecoder().decode(AppSettings.self,
      from: Data(#"{"subtitleRowSpacing":-2,"liveSubtitleRowSpacing":5}"#.utf8))
    #expect(decoded.subtitleRowSpacing == 0 && decoded.liveSubtitleRowSpacing == 1)
  }
  @Test func unknownSpeechQualityFallsBackWithoutDiscardingOtherPreferences() throws {
    let decoded = try JSONDecoder().decode(AppSettings.self,
      from: Data(#"{"wordSpeechQuality":"future-quality","cacheMB":512}"#.utf8))
    #expect(decoded.wordSpeechQuality == .standard && decoded.cacheMB == 512)
  }
  @Test func subtitleAppearanceDefaultsAreSliderMidpointsAndLegacySettingsRemainCompatible() throws {
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(decoded.subtitleWrapCharacters == (SubtitleAppearance.characterRange.lowerBound + SubtitleAppearance.characterRange.upperBound) / 2)
    #expect(decoded.subtitleFontScale == (SubtitleAppearance.fontScaleRange.lowerBound + SubtitleAppearance.fontScaleRange.upperBound) / 2)
    #expect(SubtitleAppearance.fontSize(current: true, scale: decoded.subtitleFontScale) == 26)
    #expect(SubtitleAppearance.fontSize(current: false, scale: decoded.subtitleFontScale) == 21)
    let bounded = try JSONDecoder().decode(AppSettings.self,
      from: Data(#"{"subtitleWrapCharacters":-100,"liveSubtitleWrapCharacters":999,"subtitleFontScale":-1,"liveSubtitleFontScale":9}"#.utf8))
    #expect(bounded.subtitleWrapCharacters == 20 && bounded.liveSubtitleWrapCharacters == 140)
    #expect(bounded.subtitleFontScale == 0.65 && bounded.liveSubtitleFontScale == 1.35)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(bounded)) == bounded)
  }

}
