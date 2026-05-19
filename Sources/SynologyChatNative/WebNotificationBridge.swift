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
  const notificationActions = new Map();
  const routedPostKeys = new Map();
  const nativeWindowState = { active: true };

  const post = (payload) => {
    try {
      window.webkit.messageHandlers.scnNotifications.postMessage(payload);
    } catch (_) {}
  };

  const normalizePermission = (permission) => {
    return permission === 'denied' ? 'denied' : 'granted';
  };

  const getChat = () => window.SYNO?.SDS?.Chat;

  const getCurrentChannelId = () => {
    try {
      return getChat()?.AppUtils?.Session?.getChannelId?.() ?? null;
    } catch (_) {
      return null;
    }
  };

  const getCurrentUserId = () => {
    try {
      return getChat()?.AppUtils?.Session?.getUserId?.() ?? null;
    } catch (_) {
      return null;
    }
  };

  const getNotificationMuted = () => {
    try {
      return !!getChat()?.AppUtils?.Session?.getUserPreference?.()?.notification_mute;
    } catch (_) {
      return false;
    }
  };

  const normalizeId = (value) => {
    return value === undefined || value === null ? null : String(value);
  };

  const getMessageBody = (message) => {
    try {
      return getChat()?.App?.Utils?.Notification?.getNotificationMsg?.(message) || '';
    } catch (_) {
      return '';
    }
  };

  const getMessageIcon = (message) => {
    try {
      if (message.file_props && message.file_props.is_image) {
        return getChat()?.WebAPI?.getImageUrl?.(message.post_id, 'S') || '';
      }
    } catch (_) {}
    return 'webman/3rdparty/Chat/images/icon/chat_256.png';
  };

  const registerJumpAction = (id, message) => {
    notificationActions.set(id, () => {
      try {
        getChat()?.AppUtils?.Controller?.Electron?.focusWindow?.();
        window.focus();
        getChat()?.AppUtils?.Controller?.Channel?.jumpPost?.(
          message.channel_id,
          message.post_id,
          message.isComment?.() ? message.thread_id : null
        );
      } catch (_) {}
    });
  };

  const postKey = (message) => {
    return [
      normalizeId(message.channel_id),
      normalizeId(message.post_id),
      normalizeId(message.thread_id)
    ].join(':');
  };

  const didRouteRecently = (key) => {
    const now = Date.now();
    for (const [cachedKey, timestamp] of routedPostKeys.entries()) {
      if (now - timestamp > 5000) routedPostKeys.delete(cachedKey);
    }

    const previous = routedPostKeys.get(key);
    if (previous && now - previous < 5000) return true;
    routedPostKeys.set(key, now);
    return false;
  };

  const routeChatPost = (event) => {
    const chat = getChat();
    const rawPost = event?.data || event?.post;
    if (!chat?.Record?.Msg || !rawPost) return;

    let message;
    try {
      message = new chat.Record.Msg(rawPost);
      message.channel_id = event.channel_id ?? rawPost.channel_id ?? message.channel_id;
    } catch (_) {
      return;
    }

    if (message.creator_id === getCurrentUserId()) return;
    if (message.isSystemMessage?.()) return;

    const body = getMessageBody(message);
    if (!body) return;
    if (didRouteRecently(postKey(message))) return;

    const id = `post-${message.post_id}-${message.thread_id || 0}-${Date.now()}`;
    const channelId = normalizeId(message.channel_id);
    const currentChannelId = normalizeId(getCurrentChannelId());
    registerJumpAction(id, message);

    post({
      kind: 'chatEvent',
      id,
      title: 'Chat',
      body,
      icon: getMessageIcon(message),
      channelId,
      currentChannelId,
      postId: normalizeId(message.post_id),
      threadId: normalizeId(message.thread_id),
      isCurrentChannel: channelId !== null && channelId === currentChannelId,
      muted: getNotificationMuted(),
      nativeWindowActive: nativeWindowState.active
    });
  };

  const installChatHooks = () => {
    const chat = getChat();
    const socketController = chat?.AppUtils?.Controller?.Socket;
    const notification = chat?.App?.Utils?.Notification;
    if (!socketController || !notification || socketController.__scnNativeNotificationHooked) {
      return !!socketController?.__scnNativeNotificationHooked;
    }

    socketController.__scnNativeNotificationHooked = true;

    const originalPostCreate = socketController.onPostCreate;
    if (typeof originalPostCreate === 'function') {
      socketController.onPostCreate = function(event) {
        const result = originalPostCreate.apply(this, arguments);
        routeChatPost(event);
        return result;
      };
    }

    notification.showNotification = routeChatPost;
    return true;
  };

  const scheduleChatHookInstall = () => {
    let attempts = 0;
    const timer = setInterval(() => {
      attempts += 1;
      if (installChatHooks() || attempts > 240) {
        clearInterval(timer);
      }
    }, 250);
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
    if (notification) {
      notification.dispatchEvent(new Event('click'));
      notifications.delete(id);
      return;
    }

    const action = notificationActions.get(id);
    if (!action) return;
    action();
    notificationActions.delete(id);
  };

  window.__scnSetNativeWindowActive = (active) => {
    nativeWindowState.active = !!active;
    try {
      const detector = getChat()?.AppUtils?.ActiveDetector;
      detector?.[nativeWindowState.active ? 'setBrowserActivate' : 'setBrowserDeactivate']?.();
    } catch (_) {}
  };

  window.Notification = NativeNotification;
  scheduleChatHookInstall();
})();
""",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
