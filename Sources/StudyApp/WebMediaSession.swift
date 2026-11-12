import StudyCore
import WebKit

enum WebMediaSession {
  static func payload(_ item: NowPlayingItem?, session: String) -> String {
    var value: [String: Any] = ["session": session, "subritzMediaSession": true]
    if let item {
      value["item"] = ["title": item.title, "artist": "YouTube", "album": "Subritz",
        "artwork": item.thumbnailURL.map { [["src": $0.absoluteString]] } ?? [],
        "duration": item.duration, "position": item.elapsed, "rate": item.rate,
        "state": item.state == .stopped ? "none" : item.wantsPlayback ? "playing" : "paused"]
    } else { value["item"] = NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
  static func updateScript(_ item: NowPlayingItem?, session: String) -> String {
    "window.__subritzMediaSessionUpdate?.(\(payload(item, session: session)))"
  }
  static func bootstrap(item: NowPlayingItem?, session: String) -> String {
    """
    (() => {
      const initial = \(payload(item, session: session));
      const actions = ['play', 'pause', 'stop', 'seekto', 'seekbackward', 'seekforward'];
      let current = null;
      function command(action, position) {
        window.webkit.messageHandlers.player.postMessage({session: initial.session, mediaCommand: action, position});
      }
      function apply(message) {
        if (!message || message.subritzMediaSession !== true || message.session !== initial.session) return;
        current = message;
        const info = message.item, media = navigator.mediaSession;
        if (media) {
          try {
            media.metadata = info ? new MediaMetadata({title: info.title, artist: info.artist, album: info.album, artwork: info.artwork}) : null;
            media.playbackState = info ? info.state : 'none';
            const actual = document.querySelector('video, audio');
            const position = () => actual && Number.isFinite(actual.currentTime) ? actual.currentTime : info.position;
            const handlers = info ? {
              play: () => command('play'), pause: () => command('pause'), stop: () => command('pause'),
              seekto: event => command('seek', event.seekTime),
              seekbackward: event => command('seek', Math.max(0, position() - (event.seekOffset || 15))),
              seekforward: event => command('seek', Math.min(info.duration, position() + (event.seekOffset || 15)))
            } : {};
            for (const action of actions) {
              try { media.setActionHandler(action, handlers[action] || null); } catch (_) {}
            }
            if (media.setPositionState) {
              if (info && info.duration > 0 && info.rate > 0) {
                media.setPositionState({duration: info.duration, playbackRate: info.rate,
                  position: Math.max(0, Math.min(info.position, info.duration))});
              } else { media.setPositionState(); }
            }
          } catch (_) {}
        }
        for (const frame of document.querySelectorAll('iframe')) {
          frame.contentWindow?.postMessage(message, '*');
        }
      }
      window.__subritzMediaSessionUpdate = apply;
      window.addEventListener('message', event => {
        if (event.source === window.parent) apply(event.data);
      });
      document.addEventListener('playing', () => { if (current) apply(current); }, true);
      document.addEventListener('DOMContentLoaded', () => apply(current || initial), {once: true});
      apply(initial);
    })();
    """
  }
}

/// Ephemeral stores redact Now Playing metadata, producing a generic WebKit.GPU
/// card. Give each player an isolated store and delete it when the view dies.
@MainActor enum MediaWebsiteDataStore {
  private static let key = "temporaryMediaWebsiteDataStores"
  private static var removals: [UUID: Task<Void, Never>] = [:]
  // The class-level removal API can reach an uninitialized WebKit run loop on
  // a cold launch. Construct an ephemeral store once before any removal; no
  // web view, persistent profile, or network request is needed.
  private static let initializedForRemoval: Void = { _ = WKWebsiteDataStore.nonPersistent() }()
  static func makeIdentifier() -> UUID {
    let id = UUID()
    var identifiers = UserDefaults.standard.stringArray(forKey: key) ?? []
    identifiers.append(id.uuidString)
    UserDefaults.standard.set(identifiers, forKey: key)
    return id
  }
  static func remove(_ id: UUID) {
    guard removals[id] == nil else { return }
    removals[id] = Task {
      defer { removals[id] = nil }
      do {
        try await deleteReleasedStore(id)
        let remaining = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != id.uuidString }
        UserDefaults.standard.set(remaining, forKey: key)
      } catch {} // Keep the ID for cleanup after a crash or an in-use store on next launch.
    }
  }
  static func deleteReleasedStore(_ id: UUID) async throws {
    _ = initializedForRemoval
    let delays: [UInt64] = [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 1_000_000_000]
    for attempt in 0...delays.count {
      do { try await WKWebsiteDataStore.remove(forIdentifier: id); return }
      catch {
        let error = error as NSError
        guard error.domain == "WKWebSiteDataStore", error.code == 1, attempt < delays.count else { throw error }
        // A released WKWebView may still be detaching its network-process session.
        try await Task.sleep(nanoseconds: delays[attempt])
      }
    }
  }
  static func cleanUpAbandoned() {
    // Only IDs created by this application are eligible, never browser profiles.
    for value in UserDefaults.standard.stringArray(forKey: key) ?? [] {
      if let id = UUID(uuidString: value) { remove(id) }
    }
  }
  static func finishPendingRemovals() async {
    cleanUpAbandoned()
    for task in Array(removals.values) { await task.value }
  }
}

@MainActor final class MediaWebView: WKWebView {
  private let storeID: UUID
  init(frame: CGRect, configuration: WKWebViewConfiguration, storeID: UUID) {
    self.storeID = storeID
    super.init(frame: frame, configuration: configuration)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    let id = storeID
    // WebKit requires the owning WKWebView to have been released before removal.
    Task { @MainActor in MediaWebsiteDataStore.remove(id) }
  }
}
