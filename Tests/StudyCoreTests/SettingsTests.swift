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
    }
  }
  @Test func providerModelsAndCachePathRoundTripSeparately() throws {
    var settings = AppSettings()
    settings.localModel = "Local-Model"
    settings.codexModel = " GPT-6-Luna "
    settings.cacheDirectory = "/tmp/Subritz Cache"
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    #expect(decoded.grammarModel == "Local-Model")
    var codex = decoded
    codex.provider = "codex"
    #expect(codex.grammarModel == "gpt-6-luna")
    #expect(codex.cacheURL.path == "/tmp/Subritz Cache")
    #expect(AppSettings().cacheURL == AppSettings.defaultCacheURL)
  }
}
