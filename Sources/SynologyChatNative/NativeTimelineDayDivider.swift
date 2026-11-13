import SwiftUI

struct NativeTimelineDayDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 12) {
            NativeChatColors.separator.frame(height: 1)
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundColor(NativeChatColors.muted).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(Capsule().stroke(NativeChatColors.separator))
            NativeChatColors.separator.frame(height: 1)
        }.padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Messages from " + label)
            .accessibilityAddTraits(.isHeader)
    }
}
