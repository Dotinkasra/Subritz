import Foundation

/// Observe YouTube's chrome only while a shape is visible. Root class changes and
/// user input trigger a coalesced snapshot; playback frames do not poll the DOM.
enum VideoPlayerControlRegions {
  static func update(enabled: Bool, session: String) -> String {
    "window.__subritzShapeControls?.({session:'\(session)',enabled:\(enabled)})"
  }
  static func bootstrap(enabled: Bool, session: String) -> String {
    """
    (() => {
      const session = '\(session)';
      let enabled = false, observer = null, discovery = null, timer = null, last = '';
      function snapshot() {
        timer = null;
        if (!enabled) return;
        const root = document.querySelector('.html5-video-player');
        if (!root) return;
        const rects = [];
        for (const node of root.querySelectorAll('.ytp-chrome-bottom,.ytp-chrome-top,.ytp-large-play-button,.ytp-popup,.ytp-contextmenu,.ytp-settings-menu')) {
          const style = getComputedStyle(node), rect = node.getBoundingClientRect();
          if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) < 0.05 || rect.width <= 0 || rect.height <= 0) continue;
          rects.push({x:Math.max(0,rect.left/innerWidth),y:Math.max(0,rect.top/innerHeight),
            width:Math.min(1,rect.width/innerWidth),height:Math.min(1,rect.height/innerHeight)});
        }
        const key = JSON.stringify(rects);
        if (last !== key) {
          last = key;
          window.webkit.messageHandlers.player.postMessage({session,shapeControls:rects});
        }
      }
      function schedule() { if (enabled && timer === null) timer = setTimeout(snapshot, 100); }
      function clicked() {
        if (!enabled) return;
        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(snapshot, 0);
      }
      function attach() {
        const root = document.querySelector('.html5-video-player');
        if (!root) return false;
        discovery?.disconnect(); discovery = null;
        observer?.disconnect(); observer = new MutationObserver(schedule);
        observer.observe(root,{attributes:true,attributeFilter:['class','style']});
        schedule(); return true;
      }
      function configure(message) {
        if (!message || message.session !== session || typeof message.enabled !== 'boolean') return;
        if (message.enabled !== enabled) {
          enabled = message.enabled;
          observer?.disconnect(); observer = null;
          discovery?.disconnect(); discovery = null;
          if (timer !== null) { clearTimeout(timer); timer = null; }
          last = '';
          if (enabled && !attach()) {
            discovery = new MutationObserver(attach);
            discovery.observe(document,{childList:true,subtree:true});
          }
        }
        for (const frame of document.querySelectorAll('iframe')) frame.contentWindow?.postMessage({subritzShapeControls:message},'*');
      }
      window.__subritzShapeControls = configure;
      window.addEventListener('message',event=>{if(event.source===parent && event.data?.subritzShapeControls)configure(event.data.subritzShapeControls)});
      document.addEventListener('pointermove',schedule,{passive:true});
      document.addEventListener('click',clicked,{passive:true});
      document.addEventListener('transitionend',schedule,{passive:true});
      window.addEventListener('resize',schedule,{passive:true});
      document.addEventListener('DOMContentLoaded',()=>{configure({session,enabled}); if(enabled)attach()},{once:true});
      configure({session,enabled:\(enabled)});
    })();
    """
  }
}
