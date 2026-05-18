import Foundation
import WebKit

enum Theme: String, CaseIterable {
    case original
    case modernDark
    case modernLight

    var title: String {
        switch self {
        case .original:
            return "Original Synology"
        case .modernDark:
            return "Modern Dark"
        case .modernLight:
            return "Modern Light"
        }
    }

    static var current: Theme {
        let rawValue = UserDefaults.standard.string(forKey: Defaults.theme) ?? Theme.modernDark.rawValue
        return Theme(rawValue: rawValue) ?? .modernDark
    }

    var installScript: String {
        """
        (() => {
          const id = 'synology-chat-native-theme';
          const theme = \(rawValue.javaScriptLiteral);
          const css = \(css.javaScriptLiteral);
          const root = document.documentElement;

          let style = document.getElementById(id);
          if (theme === 'original' || !css.trim()) {
            if (style) style.remove();
            delete root.dataset.scnTheme;
            return;
          }

          if (!style) {
            style = document.createElement('style');
            style.id = id;
            document.head.appendChild(style);
          }
          style.textContent = css;

          const chatSelectors = [
            '.chat-msgview',
            '.chat-msginput',
            '.chat-msg-list',
            '.channel-list-main',
            '.chat-input-aria-main-v2',
            '.msg-inputarea-textarea',
            '[class*="chat-msg"]',
            '[class*="chat-channel"]',
            '[class*="chat-room"]'
          ];

          const applyWhenChatIsReady = () => {
            const chatRoot = chatSelectors.some((selector) => document.querySelector(selector));
            if (chatRoot) {
              root.dataset.scnTheme = theme;
            } else {
              delete root.dataset.scnTheme;
            }
          };

          applyWhenChatIsReady();
          if (!window.__synologyChatNativeThemeObserver) {
            window.__synologyChatNativeThemeObserver = new MutationObserver(applyWhenChatIsReady);
            window.__synologyChatNativeThemeObserver.observe(document.documentElement, {
              childList: true,
              subtree: true
            });
          }
        })();
        """
    }

    var userScript: WKUserScript {
        WKUserScript(source: installScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private var css: String {
        switch self {
        case .original:
            ""
        case .modernDark:
            modernDarkCSS
        case .modernLight:
            modernLightCSS
        }
    }
}

private extension String {
    var javaScriptLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: self, options: .fragmentsAllowed),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }
}

private let modernDarkCSS = """
html[data-scn-theme="modernDark"] {
  color-scheme: dark;
}

html[data-scn-theme="modernDark"] body.syno-chat,
html[data-scn-theme="modernDark"] body.syno-chat .x-window,
html[data-scn-theme="modernDark"] body.syno-chat .x-window-mc,
html[data-scn-theme="modernDark"] body.syno-chat .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-content-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-content-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-content-panel > .x-panel-bwrap > .x-panel-body {
  background: #0f141c !important;
  color: #d7e4f7 !important;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-win-topbar-dsm7 {
  background: #111822 !important;
  border-bottom: 1px solid #253142 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-logo {
  filter: saturate(1.08) brightness(1.05);
}

html[data-scn-theme="modernDark"] body.syno-chat .topbar-btn,
html[data-scn-theme="modernDark"] body.syno-chat .topbar-btn .x-btn-text,
html[data-scn-theme="modernDark"] body.syno-chat .chat-account-btn {
  background-color: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .avatar,
html[data-scn-theme="modernDark"] body.syno-chat .img-avatar,
html[data-scn-theme="modernDark"] body.syno-chat .msg-avatar-icon,
html[data-scn-theme="modernDark"] body.syno-chat .fake-avatar {
  border-radius: 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .smart-search-ct-dsm7 {
  background: #141d2a !important;
  border: 1px solid #2b3748 !important;
  border-radius: 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-searchfield {
  background: transparent !important;
  color: #e8edf5 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-list-main,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-main .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-main .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-main .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-container,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-view {
  background: #12141a !important;
  color: #d9e1ec !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-border-panel:has(.jump-to-button),
html[data-scn-theme="modernDark"] body.syno-chat .x-border-panel:has(.channel-list-main),
html[data-scn-theme="modernDark"] body.syno-chat .x-panel:has(.channel-list-main),
html[data-scn-theme="modernDark"] body.syno-chat .x-panel-body:has(.channel-list-main) {
  background: #12141a !important;
  border-color: #253142 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-to-button {
  background: #141d2a !important;
  border: 1px solid #2b3748 !important;
  border-radius: 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-to-button-text,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-group-name {
  color: #778aaa !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-list-item {
  border-radius: 10px !important;
  color: #93a6c4 !important;
  margin: 2px 10px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-list-item:hover {
  background: rgba(111, 164, 255, .08) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-list-item.x-view-selected {
  background: rgba(88, 166, 255, .18) !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-list-item .name,
html[data-scn-theme="modernDark"] body.syno-chat .channel-list-item .item-title {
  color: inherit !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-msgview,
html[data-scn-theme="modernDark"] body.syno-chat .msgs {
  background: #121b27 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel > .x-panel-bwrap > .x-panel-body {
  border-top-left-radius: 10px !important;
  border-top-right-radius: 10px !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-title {
  color: #7fb2ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-title *,
html[data-scn-theme="modernDark"] body.syno-chat .msg-title .channel-star {
  color: #7fb2ff !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .item-wrap {
  background: transparent !important;
  border-radius: 10px !important;
  margin-left: 4px !important;
  margin-right: 14px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .item-wrap:hover {
  background: rgba(111, 164, 255, .08) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .item-wrap:hover .msg-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .item-wrap:hover .msg-text,
html[data-scn-theme="modernDark"] body.syno-chat .item-wrap:hover .text-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .item-wrap:hover .markdown {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-wrap {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-user-name {
  color: #f5f9ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-post-time,
html[data-scn-theme="modernDark"] body.syno-chat .system-text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-text,
html[data-scn-theme="modernDark"] body.syno-chat .text-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .markdown {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .markdown a,
html[data-scn-theme="modernDark"] body.syno-chat .msg-text a {
  color: #83b8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .date-splitter-line {
  background: transparent !important;
  border-top: 1px solid #253142 !important;
  height: 1px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .date-splitter-text {
  background: #121b27 !important;
  color: #93a6c4 !important;
  border-radius: 999px !important;
  padding: 2px 9px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .extra-date-splitter-wrapper {
  background: #121b27 !important;
  box-sizing: border-box !important;
  left: 0 !important;
  margin-left: 4px !important;
  margin-right: 14px !important;
  padding-left: 0 !important;
  padding-right: 0 !important;
  width: calc(100% - 18px) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .extra-date-splitter-wrapper .date-splitter-line {
  background: transparent !important;
  border-top: 1px solid #253142 !important;
  height: 1px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .extra-date-splitter-wrapper .date-splitter-text {
  background: #121b27 !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-input-aria-main-v2,
html[data-scn-theme="modernDark"] body.syno-chat .msg-edit-input,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel .x-panel-footer,
html[data-scn-theme="modernDark"] body.syno-chat .chat-msg-foot-toolbar {
  background: #121b27 !important;
  border-color: #253142 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-textarea-wrap {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  border-radius: 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-textarea {
  background: transparent !important;
  color: #f5f9ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-textarea:empty:before,
html[data-scn-theme="modernDark"] body.syno-chat .chat-contenteditable-field.x-form-empty-field:before {
  color: #778aaa !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-buttons {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-send-btn:not(.x-item-disabled) {
  background: #2f7df6 !important;
  border-color: #2f7df6 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-send-btn:not(.x-item-disabled) * {
  background-color: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-inputarea-send-btn .x-btn-text {
  color: #ffffff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .scroll-bottom-btn {
  background: #182333 !important;
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  box-shadow: 0 8px 22px rgba(0,0,0,.24) !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .scroll-bottom-btn .x-btn-text {
  color: #d7e4f7 !important;
  font-weight: 500 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .button_container .x-btn {
  background: #182333 !important;
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  box-shadow: none !important;
  height: 34px !important;
  margin-left: 8px !important;
  min-width: 34px !important;
  width: 34px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .button_container .x-btn:hover {
  background: #20304a !important;
  border-color: #3a4a60 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .button_container .x-btn .x-btn-text {
  background-color: transparent !important;
  filter: invert(1) brightness(1.7) saturate(.35) opacity(.86) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container {
  background: #182333 !important;
  border: 1px solid #2b3748 !important;
  border-radius: 9px !important;
  box-shadow: 0 12px 28px rgba(0,0,0,.28) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-action-divider {
  background: #2b3748 !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-hashtag-btn,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-reaction-btn,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-jump-comment-btn,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-action-btn {
  background-color: transparent !important;
  filter: invert(1) brightness(1.65) saturate(.35) opacity(.82) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-hashtag-btn:hover,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-reaction-btn:hover,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-jump-comment-btn:hover,
html[data-scn-theme="modernDark"] body.syno-chat .msg-action-container .msg-add-action-btn:hover {
  background-color: rgba(111, 164, 255, .12) !important;
  filter: invert(1) brightness(1.9) saturate(.45) opacity(.95) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-menu,
html[data-scn-theme="modernDark"] body.syno-chat .emoji-menu,
html[data-scn-theme="modernDark"] body.syno-chat .x-menu,
html[data-scn-theme="modernDark"] body.syno-chat .x-menu-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-menu-item,
html[data-scn-theme="modernDark"] body.syno-chat .x-menu-list-item,
html[data-scn-theme="modernDark"] body.syno-chat .x-menu-item-text {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-menu-item-active,
html[data-scn-theme="modernDark"] body.syno-chat .x-menu-list-item:hover {
  background: #1b2943 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-panel,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-box-inner,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-form-item,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-form-element,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-form-composite {
  background: #111a2a !important;
  border-color: transparent !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .x-window-header-text {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-input {
  background: #111a2a !important;
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  color: #d7e4f7 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-input::placeholder {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip li,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip-inner {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip {
  border-bottom: 1px solid #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip-active .x-tab-strip-inner {
  border-bottom: 3px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .jump-dialog .jump-tab-panel .x-tab-strip-text {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list {
  background: #111a2a !important;
  border: 0 !important;
  box-shadow: none !important;
  width: 560px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .x-box-inner,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .x-box-item,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list [style*="background-color: rgb(255, 255, 255)"] {
  background: #111a2a !important;
  border: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
  width: 560px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-selected,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-selected *,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover *,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover * {
  background: #182333 !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-order-time,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .addition,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .disabled-user {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-channel-item-enter:before {
  color: #83b8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-box-inner,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist [style*="background-color: rgb(255, 255, 255)"],
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .chat-infinite-list-view {
  background: #111a2a !important;
  color: #d7e4f7 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-panel-body {
  padding: 0 20px 16px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-box-inner {
  width: auto !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-box-item,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .flexcrollactive,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .scrollwrapper {
  border: 0 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-box-item:not(.chat-grouping-topblock),
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .flexcrollactive {
  left: 20px !important;
  width: calc(100% - 40px) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-grouping-topblock,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .chat-grouping-topblock,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .x-panel-header {
  background: #111a2a !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .one-row,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .search-option,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .item,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .item-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .chat-search-result-item {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-view-selected *,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-view-selected * {
  background: #182333 !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-view-over,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .x-view-over *,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-view-over,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-view-over *,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .dataview-item-over,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .dataview-item-over *,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .dataview-item-over,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .dataview-item-over * {
  background: #182333 !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .one-row:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .search-option:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .item:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .channel-list-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .member-list-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .conversation-list-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .item-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .chat-search-result-item:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .group-title,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .item-title,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .name,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .option-name,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .x-panel-header-text {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .desc,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .item-desc,
html[data-scn-theme="modernDark"] body.syno-chat .chat-groupinglist .hint,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .empty-hint-text,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .loading-text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-dataview,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-dataview .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-dataview .contentwrapper {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .app-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .app {
  border-radius: 10px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .app-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .app:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .app-launcher-panel .app-name {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tip,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-tl,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-tr,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-tc,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-ml,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-mr,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-mc,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-bl,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-br,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-bc,
html[data-scn-theme="modernDark"] body.syno-chat .x-tip-body {
  background: #111a2a !important;
  color: #d7e4f7 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tip,
html[data-scn-theme="modernDark"] body.syno-chat .pop-user-card,
html[data-scn-theme="modernDark"] body.syno-chat .user-card,
html[data-scn-theme="modernDark"] body.syno-chat .user-profile-card {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window),
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-window-mc,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-panel,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-tab-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-tab-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .syno-d-package-window,
html[data-scn-theme="modernDark"] body.syno-chat .syno-d-package-window-body {
  background: #111a2a !important;
  color: #d7e4f7 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .syno-d-package-window-header {
  background: #111a2a !important;
  border-bottom: 1px solid #4fb76a !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-window-header-text,
html[data-scn-theme="modernDark"] body.syno-chat .x-window:not(.chat-standalone-window) .x-panel-header-text,
html[data-scn-theme="modernDark"] body.syno-chat .syno-d-package-window-header-text {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip-spacer {
  background: #111a2a !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip li,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip-inner {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-strip-active,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-strip-active .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-strip-active .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-strip-active .x-tab-strip-inner {
  background: transparent !important;
  border-bottom: 3px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip-text {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-edge,
html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-edge * {
  background: transparent !important;
  border: 0 !important;
  min-width: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-tab-strip .x-tab-edge .x-tab-strip-text {
  color: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat input,
html[data-scn-theme="modernDark"] body.syno-chat textarea,
html[data-scn-theme="modernDark"] body.syno-chat .x-form-field,
html[data-scn-theme="modernDark"] body.syno-chat .x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .x-form-textarea,
html[data-scn-theme="modernDark"] body.syno-chat .v-textfield,
html[data-scn-theme="modernDark"] body.syno-chat .v-select2-wrapper {
  background: #0d131c !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat label,
html[data-scn-theme="modernDark"] body.syno-chat .x-form-item-label,
html[data-scn-theme="modernDark"] body.syno-chat .x-form-cb-label,
html[data-scn-theme="modernDark"] body.syno-chat .form-label,
html[data-scn-theme="modernDark"] body.syno-chat .syno-d-form-field-label {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-green,
html[data-scn-theme="modernDark"] body.syno-chat .chat-green-btn {
  background: #2f7df6 !important;
  border-color: #2f7df6 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-grey {
  background: #e8eef8 !important;
  border-color: #c8d3e3 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-grey .x-btn-text {
  color: #253142 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat ::selection {
  background: rgba(79, 142, 247, .42) !important;
}
"""

private let modernLightCSS = """
html[data-scn-theme="modernLight"] {
  color-scheme: light;
}

html[data-scn-theme="modernLight"] body.syno-chat,
html[data-scn-theme="modernLight"] body.syno-chat .x-window,
html[data-scn-theme="modernLight"] body.syno-chat .x-window-mc,
html[data-scn-theme="modernLight"] body.syno-chat .x-window-body,
html[data-scn-theme="modernLight"] body.syno-chat .chat-content-panel,
html[data-scn-theme="modernLight"] body.syno-chat .chat-content-panel > .x-panel-bwrap,
html[data-scn-theme="modernLight"] body.syno-chat .chat-content-panel > .x-panel-bwrap > .x-panel-body {
  background: #f4f7fb !important;
  color: #18202b !important;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .chat-win-topbar-dsm7 {
  background: #ffffff !important;
  border-bottom: 1px solid #dce3ee !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .smart-search-ct-dsm7 {
  background: #eef3f9 !important;
  border: 1px solid #d4deeb !important;
  border-radius: 15px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .chat-searchfield {
  background: transparent !important;
  color: #18202b !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .channel-list-main,
html[data-scn-theme="modernLight"] body.syno-chat .channel-list-main .x-panel-body,
html[data-scn-theme="modernLight"] body.syno-chat .channel-list-container,
html[data-scn-theme="modernLight"] body.syno-chat .channel-list-view {
  background: #eef3f9 !important;
  color: #334155 !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .jump-to-button {
  background: #ffffff !important;
  border: 1px solid #d4deeb !important;
  border-radius: 8px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .jump-to-button-text,
html[data-scn-theme="modernLight"] body.syno-chat .channel-list-group-name {
  color: #64748b !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .channel-list-item {
  border-radius: 7px !important;
  color: #334155 !important;
  margin: 2px 10px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .channel-list-item:hover {
  background: #e3ebf6 !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .channel-list-item.x-view-selected {
  background: #d8e8ff !important;
  color: #10223d !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .chat-center-content-panel,
html[data-scn-theme="modernLight"] body.syno-chat .chat-right-content-panel,
html[data-scn-theme="modernLight"] body.syno-chat .msg-panel,
html[data-scn-theme="modernLight"] body.syno-chat .msg-panel .x-panel-body,
html[data-scn-theme="modernLight"] body.syno-chat .chat-msgview,
html[data-scn-theme="modernLight"] body.syno-chat .msgs {
  background: #ffffff !important;
  color: #18202b !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-title {
  color: #0969da !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .item-wrap {
  background: transparent !important;
  border-radius: 8px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .item-wrap:hover {
  background: #f3f6fb !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-user-name {
  color: #111827 !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-post-time,
html[data-scn-theme="modernLight"] body.syno-chat .system-text {
  color: #64748b !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-text,
html[data-scn-theme="modernLight"] body.syno-chat .text-wrapper,
html[data-scn-theme="modernLight"] body.syno-chat .markdown {
  color: #18202b !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .markdown a,
html[data-scn-theme="modernLight"] body.syno-chat .msg-text a {
  color: #0969da !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .date-splitter-line {
  background: #dce3ee !important;
  border-color: #dce3ee !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .date-splitter-text {
  background: #ffffff !important;
  color: #64748b !important;
  border-radius: 999px !important;
  padding: 2px 10px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .chat-input-aria-main-v2,
html[data-scn-theme="modernLight"] body.syno-chat .msg-edit-input,
html[data-scn-theme="modernLight"] body.syno-chat .msg-panel .x-panel-footer,
html[data-scn-theme="modernLight"] body.syno-chat .chat-msg-foot-toolbar {
  background: #ffffff !important;
  border-color: #dce3ee !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-inputarea-textarea-wrap {
  background: #ffffff !important;
  border: 1px solid #cfd8e6 !important;
  border-radius: 10px !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-inputarea-textarea {
  background: transparent !important;
  color: #111827 !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-inputarea-buttons .x-btn,
html[data-scn-theme="modernLight"] body.syno-chat .button-wrap .x-btn {
  background: #f4f7fb !important;
  border: 1px solid #d4deeb !important;
  border-radius: 8px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-inputarea-send-btn:not(.x-item-disabled) {
  background: #0969da !important;
  border-color: #0969da !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .msg-inputarea-send-btn .x-btn-text {
  color: #ffffff !important;
}

html[data-scn-theme="modernLight"] body.syno-chat .chat-menu,
html[data-scn-theme="modernLight"] body.syno-chat .emoji-menu,
html[data-scn-theme="modernLight"] body.syno-chat .chat-groupinglist,
html[data-scn-theme="modernLight"] body.syno-chat .chat-search-panel {
  background: #ffffff !important;
  border-color: #d4deeb !important;
  color: #18202b !important;
  box-shadow: 0 18px 48px rgba(42,55,80,.18) !important;
}

html[data-scn-theme="modernLight"] body.syno-chat ::selection {
  background: rgba(56,139,253,.24) !important;
}
"""
