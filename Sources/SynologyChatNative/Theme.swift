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
          root.dataset.scnTheme = theme;

          let style = document.getElementById(id);
          if (theme === 'original' || !css.trim()) {
            if (style) style.remove();
            return;
          }

          if (!style) {
            style = document.createElement('style');
            style.id = id;
            document.head.appendChild(style);
          }
          style.textContent = css;
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
:root {
  color-scheme: dark;
}

html[data-scn-theme="modernDark"],
html[data-scn-theme="modernDark"] body {
  background: #111318 !important;
  color: #edf0f4 !important;
}

html[data-scn-theme="modernDark"] body,
html[data-scn-theme="modernDark"] input,
html[data-scn-theme="modernDark"] textarea,
html[data-scn-theme="modernDark"] button,
html[data-scn-theme="modernDark"] select {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif !important;
}

html[data-scn-theme="modernDark"] .x-border-layout-ct,
html[data-scn-theme="modernDark"] .x-panel,
html[data-scn-theme="modernDark"] .x-panel-body,
html[data-scn-theme="modernDark"] .x-window,
html[data-scn-theme="modernDark"] .x-container,
html[data-scn-theme="modernDark"] [class*="syno"],
html[data-scn-theme="modernDark"] [class*="Syno"] {
  background-color: #111318 !important;
  color: #edf0f4 !important;
}

html[data-scn-theme="modernDark"] [class*="toolbar"],
html[data-scn-theme="modernDark"] [class*="header"],
html[data-scn-theme="modernDark"] [class*="topbar"],
html[data-scn-theme="modernDark"] [class*="titlebar"],
html[data-scn-theme="modernDark"] .x-toolbar {
  background: #171a21 !important;
  border-color: #2a2f3a !important;
  color: #f5f6f8 !important;
}

html[data-scn-theme="modernDark"] [class*="sidebar"],
html[data-scn-theme="modernDark"] [class*="channel-list"],
html[data-scn-theme="modernDark"] [class*="conversation-list"],
html[data-scn-theme="modernDark"] [class*="left"],
html[data-scn-theme="modernDark"] .x-tree-panel,
html[data-scn-theme="modernDark"] .x-grid,
html[data-scn-theme="modernDark"] .x-grid-body {
  background: #151820 !important;
  border-color: #272c36 !important;
  color: #d9dee7 !important;
}

html[data-scn-theme="modernDark"] [class*="selected"],
html[data-scn-theme="modernDark"] [class*="active"],
html[data-scn-theme="modernDark"] .x-grid-item-selected,
html[data-scn-theme="modernDark"] .x-tree-selected {
  background: #22344f !important;
  color: #ffffff !important;
}

html[data-scn-theme="modernDark"] [class*="hover"]:hover,
html[data-scn-theme="modernDark"] .x-grid-item:hover,
html[data-scn-theme="modernDark"] .x-tree-node-text:hover {
  background: #202633 !important;
}

html[data-scn-theme="modernDark"] [class*="message"],
html[data-scn-theme="modernDark"] [class*="msg"],
html[data-scn-theme="modernDark"] [class*="post"],
html[data-scn-theme="modernDark"] [class*="thread"] {
  color: #edf0f4 !important;
  border-color: #2a2f3a !important;
}

html[data-scn-theme="modernDark"] [class*="msg-wrap"],
html[data-scn-theme="modernDark"] [class*="message-wrap"],
html[data-scn-theme="modernDark"] [class*="post-wrap"] {
  border-radius: 8px !important;
}

html[data-scn-theme="modernDark"] a {
  color: #7bb7ff !important;
}

html[data-scn-theme="modernDark"] input,
html[data-scn-theme="modernDark"] textarea,
html[data-scn-theme="modernDark"] [contenteditable="true"],
html[data-scn-theme="modernDark"] .x-form-text,
html[data-scn-theme="modernDark"] .x-form-textarea {
  background: #1c202a !important;
  color: #f5f6f8 !important;
  border-color: #343b49 !important;
  border-radius: 8px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernDark"] input::placeholder,
html[data-scn-theme="modernDark"] textarea::placeholder {
  color: #8c95a5 !important;
}

html[data-scn-theme="modernDark"] button,
html[data-scn-theme="modernDark"] .x-btn,
html[data-scn-theme="modernDark"] [role="button"] {
  border-radius: 8px !important;
  border-color: #3a4352 !important;
}

html[data-scn-theme="modernDark"] .x-menu,
html[data-scn-theme="modernDark"] .x-menu-body,
html[data-scn-theme="modernDark"] .x-boundlist,
html[data-scn-theme="modernDark"] [class*="dropdown"],
html[data-scn-theme="modernDark"] [class*="popover"],
html[data-scn-theme="modernDark"] [class*="modal"] {
  background: #1a1e27 !important;
  border-color: #303746 !important;
  color: #edf0f4 !important;
  box-shadow: 0 18px 50px rgba(0, 0, 0, .42) !important;
}

html[data-scn-theme="modernDark"] ::selection {
  background: rgba(80, 147, 255, .45) !important;
}
"""

private let modernLightCSS = """
:root {
  color-scheme: light;
}

html[data-scn-theme="modernLight"],
html[data-scn-theme="modernLight"] body {
  background: #f5f7fb !important;
  color: #18202b !important;
}

html[data-scn-theme="modernLight"] body,
html[data-scn-theme="modernLight"] input,
html[data-scn-theme="modernLight"] textarea,
html[data-scn-theme="modernLight"] button,
html[data-scn-theme="modernLight"] select {
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif !important;
}

html[data-scn-theme="modernLight"] .x-border-layout-ct,
html[data-scn-theme="modernLight"] .x-panel,
html[data-scn-theme="modernLight"] .x-panel-body,
html[data-scn-theme="modernLight"] .x-window,
html[data-scn-theme="modernLight"] .x-container,
html[data-scn-theme="modernLight"] [class*="syno"],
html[data-scn-theme="modernLight"] [class*="Syno"] {
  background-color: #f5f7fb !important;
  color: #18202b !important;
}

html[data-scn-theme="modernLight"] [class*="toolbar"],
html[data-scn-theme="modernLight"] [class*="header"],
html[data-scn-theme="modernLight"] [class*="topbar"],
html[data-scn-theme="modernLight"] [class*="titlebar"],
html[data-scn-theme="modernLight"] .x-toolbar {
  background: #ffffff !important;
  border-color: #dde3ee !important;
  color: #111827 !important;
}

html[data-scn-theme="modernLight"] [class*="sidebar"],
html[data-scn-theme="modernLight"] [class*="channel-list"],
html[data-scn-theme="modernLight"] [class*="conversation-list"],
html[data-scn-theme="modernLight"] [class*="left"],
html[data-scn-theme="modernLight"] .x-tree-panel,
html[data-scn-theme="modernLight"] .x-grid,
html[data-scn-theme="modernLight"] .x-grid-body {
  background: #eef3f9 !important;
  border-color: #dce3ee !important;
  color: #273244 !important;
}

html[data-scn-theme="modernLight"] [class*="selected"],
html[data-scn-theme="modernLight"] [class*="active"],
html[data-scn-theme="modernLight"] .x-grid-item-selected,
html[data-scn-theme="modernLight"] .x-tree-selected {
  background: #dbeafe !important;
  color: #10223d !important;
}

html[data-scn-theme="modernLight"] [class*="hover"]:hover,
html[data-scn-theme="modernLight"] .x-grid-item:hover,
html[data-scn-theme="modernLight"] .x-tree-node-text:hover {
  background: #e7edf6 !important;
}

html[data-scn-theme="modernLight"] [class*="message"],
html[data-scn-theme="modernLight"] [class*="msg"],
html[data-scn-theme="modernLight"] [class*="post"],
html[data-scn-theme="modernLight"] [class*="thread"] {
  color: #18202b !important;
  border-color: #dde3ee !important;
}

html[data-scn-theme="modernLight"] [class*="msg-wrap"],
html[data-scn-theme="modernLight"] [class*="message-wrap"],
html[data-scn-theme="modernLight"] [class*="post-wrap"] {
  border-radius: 8px !important;
}

html[data-scn-theme="modernLight"] a {
  color: #0969da !important;
}

html[data-scn-theme="modernLight"] input,
html[data-scn-theme="modernLight"] textarea,
html[data-scn-theme="modernLight"] [contenteditable="true"],
html[data-scn-theme="modernLight"] .x-form-text,
html[data-scn-theme="modernLight"] .x-form-textarea {
  background: #ffffff !important;
  color: #111827 !important;
  border-color: #cfd8e6 !important;
  border-radius: 8px !important;
  box-shadow: none !important;
}

html[data-scn-theme="modernLight"] button,
html[data-scn-theme="modernLight"] .x-btn,
html[data-scn-theme="modernLight"] [role="button"] {
  border-radius: 8px !important;
  border-color: #cfd8e6 !important;
}

html[data-scn-theme="modernLight"] .x-menu,
html[data-scn-theme="modernLight"] .x-menu-body,
html[data-scn-theme="modernLight"] .x-boundlist,
html[data-scn-theme="modernLight"] [class*="dropdown"],
html[data-scn-theme="modernLight"] [class*="popover"],
html[data-scn-theme="modernLight"] [class*="modal"] {
  background: #ffffff !important;
  border-color: #dbe2ee !important;
  color: #18202b !important;
  box-shadow: 0 18px 50px rgba(42, 55, 80, .18) !important;
}

html[data-scn-theme="modernLight"] ::selection {
  background: rgba(56, 139, 253, .24) !important;
}
"""
