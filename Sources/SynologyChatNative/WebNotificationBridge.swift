import Foundation
import WebKit

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

enum WebNotificationBridge {
    static let handlerName = "scnNotifications"

    static let userScript = WKUserScript(
        source: """
(() => {
  if (window.__scnNativeNotificationInstalled || !window.webkit?.messageHandlers?.scnNotifications) {
    return;
  }

  window.__scnNativeNotificationInstalled = true;
  const notifications = new Map();

  const post = (payload) => {
    try {
      window.webkit.messageHandlers.scnNotifications.postMessage(payload);
    } catch (_) {}
  };

  const normalizePermission = (permission) => {
    return permission === 'denied' ? 'denied' : 'granted';
  };

  function NativeNotification(title, options = {}) {
    const id = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const listeners = {};
    let onclick = null;
    let closed = false;

    this.title = String(title || '');
    this.body = options.body ? String(options.body) : '';
    this.icon = options.icon ? String(options.icon) : '';
    this.tag = options.tag ? String(options.tag) : '';

    Object.defineProperty(this, 'onclick', {
      get() { return onclick; },
      set(handler) { onclick = typeof handler === 'function' ? handler : null; }
    });

    this.addEventListener = (type, handler) => {
      if (typeof handler !== 'function') return;
      if (!listeners[type]) listeners[type] = new Set();
      listeners[type].add(handler);
    };

    this.removeEventListener = (type, handler) => {
      listeners[type]?.delete(handler);
    };

    this.dispatchEvent = (event) => {
      const type = event?.type;
      if (!type) return true;
      if (type === 'click' && onclick) onclick.call(this, event);
      listeners[type]?.forEach((handler) => handler.call(this, event));
      return true;
    };

    this.close = () => {
      if (closed) return;
      closed = true;
      notifications.delete(id);
      post({ kind: 'close', id });
    };

    notifications.set(id, this);
    post({
      kind: 'show',
      id,
      title: this.title,
      body: this.body,
      icon: this.icon,
      tag: this.tag,
      url: location.href
    });
  }

  NativeNotification.permission = 'default';
  NativeNotification.maxActions = 0;

  NativeNotification.requestPermission = (callback) => {
    post({ kind: 'requestPermission' });
    const permission = normalizePermission(NativeNotification.permission);
    if (typeof callback === 'function') {
      setTimeout(() => callback(permission), 0);
      return undefined;
    }
    return Promise.resolve(permission);
  };

  window.__scnDispatchNativeNotificationClick = (id) => {
    const notification = notifications.get(id);
    if (!notification) return;
    notification.dispatchEvent(new Event('click'));
    notifications.delete(id);
  };

  window.Notification = NativeNotification;
})();
""",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
