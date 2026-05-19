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

html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar {
  overflow: visible !important;
}

html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar {
  border-radius: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar .img-avatar,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar .fake-avatar,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar .synobot-avatar {
  border-radius: 50% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-app .chat-win-topbar-dsm7 .chat-account-btn .avatar .online-status {
  border-color: #111822 !important;
  bottom: -1px !important;
  right: -1px !important;
  z-index: 3 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window.light-theme,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .v-window-header-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .v-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .v-about-window-body-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .content-top,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .content-bottom {
  background: #111a2a !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .v-about-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .content-row.name {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .divider {
  background: #2b3748 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .links a {
  color: #7fb2ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .copyright {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .window-header-tool-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .window-header-tool-wrapper.light,
html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .window-tool-close {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .v-about-window .window-tool-close:hover {
  color: #d7e4f7 !important;
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
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel > .x-panel-bwrap > .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel > .x-panel-bwrap > .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel,
html[data-scn-theme="modernDark"] body.syno-chat .msg-panel > .x-panel-bwrap,
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

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .msg-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .msg-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .msg-panel > .x-panel-bwrap > .x-panel-body {
  border-bottom-right-radius: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .scrollwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .scrollgeneric,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbase,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbasebeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbaseend,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbar,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbarbeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .vscrollerbarend {
  background-color: #121b27 !important;
  background-image: none !important;
  border-color: #121b27 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .scrollwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed .chat-msgview .scrollgeneric {
  border-radius: 0 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-center-content-panel.collapsed::after {
  content: none !important;
  display: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel {
  border-top-left-radius: 10px !important;
  border-top-right-radius: 10px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel > .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel > .x-panel-bwrap > .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel {
  border-top-left-radius: 10px !important;
  border-top-right-radius: 10px !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-panel-tbar,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-toolbar,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .post-list-view,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .scrollwrapper {
  background: #121b27 !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip {
  border-bottom: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-spacer {
  background: transparent !important;
  border: 0 !important;
  height: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active .x-tab-strip-inner {
  border-bottom: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active .x-tab-strip-text {
  border-bottom: 2px solid #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active {
  border-bottom: 2px solid #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-text,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .sortby-btn button,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .close-tab-panel-btn button {
  filter: invert(1) brightness(1.45) saturate(.4) opacity(.82) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-summary-tab-panel .x-tab-strip-active .x-tab-strip-text {
  filter: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .sortby-btn,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .sortby-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .sortby-btn button,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .close-tab-panel-btn,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .close-tab-panel-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .close-tab-panel-btn button {
  background-color: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .empty-hint {
  background: transparent !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .empty-hint-text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .empty-hint-img {
  filter: invert(1) brightness(1.3) saturate(.35) opacity(.45) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-infinite-list-view .item-wrap {
  border: 1px solid #2b3748 !important;
  border-radius: 0 !important;
  margin: 0 0 6px 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .chat-infinite-list-view .item-wrap:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-wrap.allowDefCtxMenu {
  background: #121b27 !important;
  border-color: #9aa8b9 !important;
  box-sizing: border-box !important;
  color: #d7e4f7 !important;
  max-width: 100% !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-wrap.allowDefCtxMenu:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-additional-wrapper {
  background: transparent !important;
  box-sizing: border-box !important;
  color: #93a6c4 !important;
  max-width: 100% !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-count {
  color: #93a6c4 !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .action-buttons {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-jump-btn,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .msg-more-btn {
  background-color: transparent !important;
  filter: invert(1) brightness(1.6) saturate(.35) opacity(.9) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .button-divider {
  background: #526174 !important;
  opacity: .75 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .x-form-field-wrap {
  background: #0f1723 !important;
  border: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-combo-box {
  background: #0f1723 !important;
  border: 1px solid #2b3748 !important;
  border-right: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .syno-ux-combobox-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .x-form-arrow-trigger {
  background: #0f1723 !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 12px 12px !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  box-shadow: none !important;
  filter: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-combo-box:focus,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-combo-box.x-form-focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-combo-box:focus + .x-form-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-combo-box.x-form-focus + .x-form-trigger {
  border-color: #4f8ef7 !important;
  border-left: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-list-view,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-list-view .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-list-view .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-list-view .scrollwrapper {
  background: #121b27 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-wrap {
  background: transparent !important;
  border-bottom: 1px solid #9aa8b9 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-wrap:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .file-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .inner-wrapper {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-file-name {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-file-size {
  color: #c2cee0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .action-buttons {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-jump-btn,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .msg-more-btn {
  background-color: transparent !important;
  filter: invert(1) brightness(1.6) saturate(.35) opacity(.9) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .button-divider {
  background: #526174 !important;
  opacity: .75 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbase,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbasebeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbaseend {
  background: #0f1723 !important;
  border-color: #0f1723 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbar,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbarbeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .file-tab-panel .vscrollerbarend {
  background: #38465a !important;
  border-color: #38465a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .scrollwrapper {
  background: #121b27 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .msg-wrap {
  background: transparent !important;
  border: 1px solid #9aa8b9 !important;
  box-sizing: border-box !important;
  color: #d7e4f7 !important;
  margin: 0 0 6px 0 !important;
  max-width: 100% !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .msg-wrap:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-text-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-image-wrapper {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-title {
  color: #7fb2ff !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-desc {
  color: #93a6c4 !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-domain {
  color: #c2cee0 !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-image-wrapper {
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .url-image {
  background-color: #0f1723 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .action-buttons {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .msg-jump-btn,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .msg-more-btn {
  background-color: transparent !important;
  filter: invert(1) brightness(1.6) saturate(.35) opacity(.9) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .button-divider {
  background: #526174 !important;
  opacity: .75 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbase,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbasebeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbaseend {
  background: #0f1723 !important;
  border-color: #0f1723 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbar,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbarbeg,
html[data-scn-theme="modernDark"] body.syno-chat .chat-right-content-panel .summary-item .url-list-view .vscrollerbarend {
  background: #38465a !important;
  border-color: #38465a !important;
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

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap {
  background: transparent !important;
  border-bottom: 1px solid #2b3748 !important;
  border-radius: 0 !important;
  margin-left: 0 !important;
  margin-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap .title-wrapper .title,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap .title-wrapper .title {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap .desc,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap .desc {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap.x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap.x-view-selected {
  background: #182333 !important;
  border-bottom-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap .title-wrapper .disabled-label,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap .title-wrapper .disabled-label,
html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap:hover .title-wrapper .disabled-label,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap:hover .title-wrapper .disabled-label {
  background: #111a2a !important;
  color: #71819a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap .title-wrapper .disabled-label::before,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap .title-wrapper .disabled-label::before {
  background: linear-gradient(to right, rgba(17,26,42,0), #111a2a) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .integration-dialog .integration-list .item-wrap:hover .title-wrapper .disabled-label::before,
html[data-scn-theme="modernDark"] body.syno-chat.syno-chat-admin .integration-listview .item-wrap:hover .title-wrapper .disabled-label::before {
  background: linear-gradient(to right, rgba(24,35,51,0), #182333) !important;
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

html[data-scn-theme="modernDark"] body.syno-chat .new-msg-splitter-line {
  background: transparent !important;
  border-top: 1px solid #2b3748 !important;
  height: 1px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .new-msg-splitter-text {
  background: #182333 !important;
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  color: #58c56f !important;
  padding: 2px 10px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-wrapper {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-hello {
  color: #d7e4f7 !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-desc {
  background-color: #182333 !important;
  border: 0 !important;
  border-radius: 6px !important;
  border-bottom-left-radius: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-desc > div {
  background: transparent !important;
  border: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-desc::before {
  background: transparent !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='9' height='13' viewBox='0 0 9 13'%3E%3Cpath fill='%23182333' d='M9 0v13H0c4.9-1.1 8.2-5.9 9-13Z'/%3E%3C/svg%3E") !important;
  background-repeat: no-repeat !important;
  background-size: 9px 13px !important;
  border: 0 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .welcome-desc b {
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .item-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .item {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .item-title,
html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .bold {
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .item-desc {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .indicator,
html[data-scn-theme="modernDark"] body.syno-chat .bot-welcome-wrapper .arrow {
  filter: invert(1) brightness(1.4) saturate(.4) opacity(.85) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .x-border-layout-ct,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .x-border-panel,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .chat-msgview,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msgs {
  background: #121b27 !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .item-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap {
  background: transparent !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .item-wrap.x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .item-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap.x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap.active {
  background: rgba(111, 164, 255, .08) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap.thread-header,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap.thread-header.x-view-selected,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-wrap.thread-header .msg-additional-wrapper {
  background: #182333 !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-user-name,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-user-name *,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-text,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .text-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .markdown {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-post-time,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-count {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .thread-subscribe-btn {
  background: #111a2a !important;
  border-color: #526174 !important;
  color: #c6d2e3 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .thread-subscribe-btn:hover {
  background: #223149 !important;
  border-color: #7fb2ff !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-comment-divider {
  background: #526174 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .chat-input-aria-main-v2,
html[data-scn-theme="modernDark"] body.syno-chat .chat-thread-dialog .msg-inputarea-buttons {
  background: #121b27 !important;
  border-color: #253142 !important;
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
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover {
  background: #182333 !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-selected .name,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-selected .channel-order-time,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-selected .chat-channel-item-enter,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover .name,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover .channel-order-time,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .chat-groupinglist-item:hover .chat-channel-item-enter,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover .name,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover .channel-order-time,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .channel-list-item:hover .chat-channel-item-enter {
  background: transparent !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .avatar-wrap,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .avatar-wrap *,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .fake-avatar,
html[data-scn-theme="modernDark"] body.syno-chat #chat-jump-list .online-status {
  color: #ffffff !important;
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
  padding: 0 0 14px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .x-box-inner {
  width: 100% !important;
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
  left: 0 !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .chat-grouping-topblock,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel .chat-grouping-topblock,
html[data-scn-theme="modernDark"] body.syno-chat .chat-search-panel .x-panel-header {
  background: #111a2a !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist {
  background: #111a2a !important;
  border: 1px solid #2b3748 !important;
  border-radius: 8px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .x-box-inner,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .x-box-item,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist [style*="background-color: rgb(255, 255, 255)"] {
  background: #111a2a !important;
  color: #d7e4f7 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-grouping-topblock {
  padding: 0 20px !important;
  box-sizing: border-box !important;
  line-height: 46px !important;
  font-weight: 700 !important;
  color: #d7e4f7 !important;
  text-align: left !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-listitem-header {
  margin: 0 20px !important;
  padding: 0 !important;
  height: 26px !important;
  line-height: 26px !important;
  background: transparent !important;
  border-bottom: 1px solid #2b3748 !important;
  box-sizing: border-box !important;
  color: #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem {
  padding: 0 20px !important;
  box-sizing: border-box !important;
  height: 34px !important;
  line-height: 34px !important;
  background: transparent !important;
  color: #a7b2c4 !important;
  white-space: nowrap !important;
  overflow: hidden !important;
  text-overflow: ellipsis !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem .highlight {
  background: transparent !important;
  color: #d7e4f7 !important;
  font-weight: 700 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem:hover,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem:hover *,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem.x-view-over,
html[data-scn-theme="modernDark"] body.syno-chat .search-list-panel.chat-groupinglist .chat-searchitem.x-view-over * {
  background: #182333 !important;
  color: #f4f8ff !important;
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

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-window-footer,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-panel-fbar,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .snippet-form,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .snippet-form .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .snippet-form .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog form.x-form {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .label-container,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .label-container .x-box-inner,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .label-container .display-label {
  background: transparent !important;
  border: 0 !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .chat-contenteditable-field.with-border {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  color: #d7e4f7 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog input.x-form-text:focus,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .chat-contenteditable-field.with-border:focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-form-field-trigger-wrap {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-form-field-trigger-wrap input.x-form-text {
  border-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-form-trigger {
  background: #0d131c !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 12px 12px !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  filter: none !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-form-field-trigger-wrap input.x-form-text:focus + .x-form-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .x-form-field-trigger-wrap input.x-form-focus + .x-form-trigger {
  border-color: #4f8ef7 !important;
  border-left: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .editor-container.ace_editor,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_scroller,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_content,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_layer {
  background: #0d131c !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .editor-container.ace_editor {
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_gutter,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_gutter-layer,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_gutter-cell {
  background: #121b28 !important;
  color: #93a6c4 !important;
  border-color: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_active-line,
html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_gutter-active-line {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_cursor {
  border-left-color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .snippet-dialog .ace_print-margin {
  background: #253142 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-footer,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-panel-fbar,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .scrollbar-wrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-formpanel,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-formpanel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog form.x-form,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-fieldset,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-fieldset-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-fieldset-body,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choices {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-window-footer {
  border-top: 1px solid #223149 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-item-label,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-checkbox-label {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-fieldset.x-fieldset {
  border: 0 !important;
  padding-top: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-fieldset.x-fieldset .x-fieldset-header {
  background: transparent !important;
  border-bottom: 1px dashed #526174 !important;
  color: #93a6c4 !important;
  display: block !important;
  margin-bottom: 14px !important;
  padding-bottom: 5px !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-fieldset.x-fieldset .x-fieldset-header .x-fieldset-header-text {
  background: transparent !important;
  color: #93a6c4 !important;
  display: block !important;
  font-weight: 700 !important;
  padding: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog textarea.x-form-textarea,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-field-wrap {
  background: #0d131c !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog textarea.x-form-textarea {
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog input.x-form-text:focus,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog textarea.x-form-textarea:focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-element,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-inner-element,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-element .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-element .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-element .scrollwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .syno-ux-form-fleXcroll-element .scrollgeneric {
  background: transparent !important;
  border: 0 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .file-btn,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .file-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .file-btn button,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .btn-add-option,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .btn-add-option em,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .btn-add-option button {
  background: transparent !important;
  border-color: transparent !important;
  color: #d7e4f7 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .file-btn:hover button,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .btn-add-option:hover button {
  color: #7fb2ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-field-trigger-wrap {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-composite:has(input[name="on_date"]),
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-composite:has(input[name="on_date"]) .x-box-inner {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-field-trigger-wrap input.x-form-text {
  border-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-trigger {
  background: #0d131c !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 12px 12px !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  filter: none !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choice.x-form-field,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choice .x-box-inner {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choice .x-box-inner > .x-btn,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choice .x-box-inner > .x-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .choice .x-box-inner > .x-btn button {
  background-color: transparent !important;
  border: 0 !important;
  box-shadow: none !important;
  line-height: 0 !important;
  margin-right: 0 !important;
  padding: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-split-bar {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-item-disabled,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-item-disabled * {
  color: #71819a !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap {
  align-items: center !important;
  background: transparent !important;
  color: #d7e4f7 !important;
  display: flex !important;
  gap: 8px !important;
  min-height: 30px !important;
  padding: 0 !important;
  position: relative !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap .syno-ux-checkbox-label {
  background: transparent !important;
  color: #d7e4f7 !important;
  display: block !important;
  line-height: 18px !important;
  margin-left: 0 !important;
  min-height: 18px !important;
  padding-left: 0 !important;
  vertical-align: baseline !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap input.syno-ux-checkbox-icon {
  height: 18px !important;
  left: 0 !important;
  margin: 0 !important;
  opacity: 0 !important;
  position: absolute !important;
  top: 6px !important;
  width: 18px !important;
  z-index: 2 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap div.syno-ux-checkbox-icon {
  background: #0d131c !important;
  border: 1px solid #9fb0c7 !important;
  border-radius: 2px !important;
  box-shadow: none !important;
  box-sizing: border-box !important;
  flex: 0 0 18px !important;
  height: 18px !important;
  margin: 0 !important;
  position: relative !important;
  width: 18px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-hover,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-focus {
  border-color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-checked {
  background: #57bf6d !important;
  border-color: #57bf6d !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-checked::after {
  border: solid #ffffff !important;
  border-width: 0 2px 2px 0 !important;
  content: "" !important;
  height: 9px !important;
  left: 5px !important;
  position: absolute !important;
  top: 1px !important;
  transform: rotate(45deg) !important;
  width: 5px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn button {
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn {
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .create-vote-dialog .chat-grey-btn button {
  border: 0 !important;
  border-radius: 999px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-footer,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-panel-fbar,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .syno-ux-formpanel,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .syno-ux-formpanel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog form.x-form {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-window-footer {
  border-top: 1px solid #223149 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-item-label {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .desc-schedule-send {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .chat-contenteditable-field.with-border,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-field-wrap {
  background: #0d131c !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .chat-contenteditable-field.with-border {
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog input.x-form-text:focus,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .chat-contenteditable-field.with-border:focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-field-trigger-wrap {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-composite:has(input[name="on_date"]),
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-composite:has(input[name="on_date"]) .x-box-inner {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-field-trigger-wrap input.x-form-text {
  border-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-trigger {
  background-color: #0d131c !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  filter: none !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .x-form-arrow-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .syno-ux-combobox-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .syno-ux-timefield-trigger {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-size: 12px 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .syno-ux-datefield-trigger {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='15' height='15' viewBox='0 0 15 15'%3E%3Crect x='2.25' y='3.25' width='10.5' height='9.5' rx='1.2' fill='none' stroke='%2393a6c4' stroke-width='1.3'/%3E%3Cpath d='M4.5 1.8v3M10.5 1.8v3M2.7 6.1h9.6' stroke='%2393a6c4' stroke-width='1.3' stroke-linecap='round'/%3E%3Ccircle cx='5' cy='8.5' r='.65' fill='%2393a6c4'/%3E%3Ccircle cx='7.5' cy='8.5' r='.65' fill='%2393a6c4'/%3E%3Ccircle cx='10' cy='8.5' r='.65' fill='%2393a6c4'/%3E%3Ccircle cx='5' cy='10.8' r='.65' fill='%2393a6c4'/%3E%3Ccircle cx='7.5' cy='10.8' r='.65' fill='%2393a6c4'/%3E%3C/svg%3E") !important;
  background-size: 15px 15px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .chat-split-bar {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .create-schedule-emoji-btn,
html[data-scn-theme="modernDark"] body.syno-chat .create-schedule-message-dialog .create-schedule-emoji-btn button {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-footer,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-panel-fbar,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-tab-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-tab-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .profile-panel,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .profile-panel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .profile-panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-formpanel,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-formpanel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .contentwrapper {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-header-text,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .profile-panel-user {
  color: #d7e4f7 !important;
  font-weight: 700 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-inner {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip {
  border-bottom: 1px solid #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-active .x-tab-strip-inner {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-active::before,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-active::after {
  border: 0 !important;
  display: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip-text,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-item-label {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .title,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .header,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-item-label,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-cb-label,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-display-field,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-box-item {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .desc,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .description,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .hint,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-item-disabled,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-item-disabled * {
  color: #71819a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .avatar-ct {
  background: #111a2a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .avatar {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .upload-mask {
  background: rgba(13, 19, 28, .82) !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog textarea.x-form-textarea,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-wrap {
  background: #0d131c !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog textarea.x-form-textarea {
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-wrap {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-wrap input.x-form-text {
  border: 1px solid #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-trigger-wrap input.x-form-text {
  border-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog input.x-form-text:focus,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog textarea.x-form-textarea:focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-trigger-wrap input.x-form-text:focus + .x-form-trigger,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-field-trigger-wrap input.x-form-focus + .x-form-trigger {
  border-color: #4f8ef7 !important;
  border-left: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-trigger {
  background: #0d131c !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 12px 12px !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  filter: none !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-element,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-inner-element {
  background: transparent !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .profile-panel-desc {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-element .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-element .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-element .scrollwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-form-fleXcroll-element .scrollgeneric {
  background: transparent !important;
  border: 0 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-window-footer {
  border-top: 1px solid #223149 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-status-text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-fieldset.x-fieldset,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-fieldset.x-fieldset .x-fieldset-header {
  background: transparent !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-fieldset.x-fieldset {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-fieldset.x-fieldset .x-fieldset-header {
  border-bottom: 1px dashed #526174 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .syno-ux-fieldset.x-fieldset .x-fieldset-header .x-fieldset-header-text {
  background: transparent !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-group,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-group .x-column-inner,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-group .x-column,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .theme-panel,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .theme-ct,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .wallpaper-panel,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .wallpaper-ct {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog input[type="checkbox"],
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog input[type="radio"] {
  accent-color: #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-wrap {
  border-radius: 4px !important;
  min-height: 30px !important;
  padding: 0 !important;
  position: relative !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap .syno-ux-checkbox-label,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-radio-wrap .syno-ux-checkbox-label {
  color: #d7e4f7 !important;
  display: block !important;
  line-height: 30px !important;
  min-height: 30px !important;
  padding-left: 26px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap input.syno-ux-checkbox-icon,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap input.syno-ux-radio-icon {
  cursor: pointer !important;
  height: 18px !important;
  left: 0 !important;
  margin: 0 !important;
  opacity: 0 !important;
  position: absolute !important;
  top: 6px !important;
  width: 18px !important;
  z-index: 2 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon {
  background: #0d131c !important;
  background-image: none !important;
  border: 1px solid #93a6c4 !important;
  box-sizing: border-box !important;
  filter: none !important;
  height: 18px !important;
  left: 0 !important;
  margin: 0 !important;
  position: absolute !important;
  top: 6px !important;
  width: 18px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon {
  border-radius: 2px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon {
  border-radius: 50% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-hover,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-focus,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon.syno-ux-cb-hover,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon.syno-ux-cb-focus {
  border-color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-checked,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon.syno-ux-cb-checked {
  background: #58c56f !important;
  border-color: #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-checkbox-icon.syno-ux-cb-checked {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='18' height='18' viewBox='0 0 18 18'%3E%3Cpath d='M4.2 8.8 7.3 12 13.8 5.3' fill='none' stroke='%23fff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 18px 18px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-form-check-wrap div.syno-ux-radio-icon.syno-ux-cb-checked {
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='18' height='18' viewBox='0 0 18 18'%3E%3Ccircle cx='9' cy='9' r='4' fill='%23fff'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 18px 18px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn button {
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
  border-radius: 999px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn {
  border: 1px solid #2b3748 !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn button {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn button {
  background: #2f7df6 !important;
  background-image: none !important;
  border-color: #2f7df6 !important;
  color: #ffffff !important;
  border-radius: 999px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn {
  border: 1px solid #2f7df6 !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-green-btn button {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn.x-item-disabled,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn.x-item-disabled em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-grey-btn.x-item-disabled button {
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  color: #71819a !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list,
html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list .x-combo-list-inner,
html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list .x-combo-list-item {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list {
  border: 1px solid #2b3748 !important;
  border-radius: 8px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list .x-combo-list-item {
  padding: 7px 12px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list .x-combo-selected,
html[data-scn-theme="modernDark"] body.syno-chat .x-combo-list .x-combo-list-item:hover {
  background: #182333 !important;
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-tl,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-tr,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-tc,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-ml,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-mr,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-mc,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-bl,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-br,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-bc,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .cal_todo,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-panel-tbar,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_listview,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .contentwrapper {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-header {
  background: #111a2a !important;
  border-bottom: 1px solid #4fb76a !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-window-header-text,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .main_title {
  color: #d7e4f7 !important;
  font-weight: 700 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .cal_todo_upper_bar {
  background: #111a2a !important;
  border-bottom: 1px solid #223149 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .upper_bar_btn,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .upper_bar_btn em,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .upper_bar_btn button {
  background-color: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .upper_bar_btn button,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .x-tool {
  filter: invert(1) brightness(1.65) saturate(.35) opacity(.82) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_create_textarea {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  border-radius: 8px !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .text_content,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .text_content_wrap {
  background: transparent !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .text_content:empty:before {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .empty_text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .empty_icon {
  filter: invert(1) brightness(1.3) saturate(.35) opacity(.5) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .cal_list,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .contentwrapper {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel {
  border-right: 1px solid #2b3748 !important;
  box-shadow: 14px 0 32px rgba(0,0,0,.28) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn button {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn:hover,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn-pressed {
  background: #182333 !important;
  border-radius: 8px !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn-pressed button,
html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .x-btn:hover button {
  color: #f4f8ff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .header.todo_list {
  background: transparent !important;
  border-bottom: 1px solid #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .title {
  color: #93a6c4 !important;
  text-transform: uppercase !important;
  letter-spacing: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .add_text {
  color: #58c56f !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_list_panel .add_input {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .cal_todo_window .todo_mask {
  background: rgba(7, 12, 20, .66) !important;
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

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-strip-inner {
  border-bottom: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-strip-text {
  border-bottom: 1px solid #4fb76a !important;
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

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-footer,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-panel-fbar,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-tab-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-tab-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .notification-settings-tab,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg form.x-form,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-fieldset,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-fieldset-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-fieldset-body {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-header-text {
  color: #d7e4f7 !important;
  font-weight: 700 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-window-footer {
  border-top: 1px solid #223149 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-panel-header,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip-wrap,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip-inner {
  background: transparent !important;
  border-color: transparent !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip {
  border-bottom: 1px solid #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-right,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-left,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-strip-inner {
  border-bottom: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip .x-tab-strip-active .x-tab-strip-text {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip-active::before,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-modal-tab-panel .x-tab-strip-active::after {
  border: 0 !important;
  display: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-tab-strip-text,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-item-label {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .syno-ux-fieldset.x-fieldset {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .syno-ux-fieldset.x-fieldset .x-fieldset-header {
  background: transparent !important;
  border-bottom: 1px dashed #526174 !important;
  color: #93a6c4 !important;
  display: block !important;
  margin-bottom: 12px !important;
  padding-bottom: 5px !important;
  width: 100% !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .syno-ux-fieldset.x-fieldset .x-fieldset-header .x-fieldset-header-text {
  background: transparent !important;
  color: #93a6c4 !important;
  display: block !important;
  font-weight: 700 !important;
  padding: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-display-field {
  background: transparent !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg input.x-form-text,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-field-wrap {
  background: #0d131c !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg input.x-form-text {
  border: 1px solid #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg input.x-form-text:focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-field-trigger-wrap {
  background: transparent !important;
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-field-trigger-wrap input.x-form-text {
  border-right: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .x-form-trigger {
  background: #0d131c !important;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%2393a6c4' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-size: 12px 12px !important;
  border: 1px solid #2b3748 !important;
  border-left: 0 !important;
  filter: none !important;
  opacity: 1 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn button {
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  border-radius: 999px !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn {
  border: 1px solid #2b3748 !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-grey-btn button {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn button {
  background: #2f7df6 !important;
  background-image: none !important;
  border-color: #2f7df6 !important;
  border-radius: 999px !important;
  box-shadow: none !important;
  color: #ffffff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn {
  border: 1px solid #2f7df6 !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .channel-setting-dlg .chat-green-btn button {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-window-header,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-window-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-window-body,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .main-member-dialog,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-panel-bwrap,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-panel-tbar,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-toolbar,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-toolbar-ct,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-toolbar-left,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-toolbar-right,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-panel-body,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-border-layout-ct,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-border-panel,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .mcontentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .contentwrapper,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .scrollwrapper {
  background: #111a2a !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog {
  border: 1px solid #2b3748 !important;
  border-radius: 10px !important;
  box-shadow: 0 18px 48px rgba(0,0,0,.42) !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-window-header {
  border-bottom: 1px solid #4fb76a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .x-window-header-text {
  color: #d7e4f7 !important;
  font-weight: 700 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn button {
  background: #2f7df6 !important;
  background-image: none !important;
  border-color: #2f7df6 !important;
  border-radius: 999px !important;
  box-shadow: none !important;
  color: #ffffff !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn {
  border: 1px solid #2f7df6 !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .chat-create-btn button {
  border: 0 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter .x-form-field-wrap {
  background: #0d131c !important;
  border: 1px solid #2b3748 !important;
  border-radius: 8px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter .x-form-field-wrap:hover,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter .x-form-field-wrap.x-trigger-wrap-focus {
  border-color: #4f8ef7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter .x-form-text.syno-ux-textfilter-text {
  background: transparent !important;
  border: 0 !important;
  box-shadow: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter .x-form-text.syno-ux-textfilter-text::placeholder {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .syno-ux-textfilter-trigger {
  background-color: transparent !important;
  border: 0 !important;
  filter: invert(1) brightness(1.45) saturate(.4) opacity(.75) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .member-wrap {
  background: transparent !important;
  border-color: transparent !important;
  border-radius: 8px !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .member-wrap:hover {
  background: #182333 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .member-wrap.current-user {
  background: rgba(111, 164, 255, .08) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .user-name {
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .user-name .addition {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .disabled-user,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .disabled-user * {
  color: #71819a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .online-status {
  border-color: #111a2a !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .btn-area .divider {
  background: #2b3748 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .btn-area .edit-user,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .btn-area .kick-user,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .btn-area .add-user,
html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .member-list-dataview .btn-area .rescue-user {
  filter: invert(1) brightness(1.45) saturate(.4) opacity(.82) !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .empty-hint {
  background: transparent !important;
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .empty-hint-text {
  color: #93a6c4 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .member-dialog .empty-hint-img {
  filter: invert(1) brightness(1.3) saturate(.35) opacity(.5) !important;
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
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-grey em,
html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-grey button,
html[data-scn-theme="modernDark"] body.syno-chat .x-btn.syno-ux-button-grey .x-btn-text {
  background: transparent !important;
  background-image: none !important;
  color: #d7e4f7 !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn button,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn .x-btn-text {
  background: #182333 !important;
  background-image: none !important;
  border-color: #2b3748 !important;
  color: #d7e4f7 !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn {
  border: 1px solid #2b3748 !important;
  border-radius: 999px !important;
  overflow: hidden !important;
}

html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn em,
html[data-scn-theme="modernDark"] body.syno-chat .user-preference-dialog .x-btn.syno-ux-button-grey.chat-grey-btn button {
  border: 0 !important;
  border-radius: 999px !important;
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
