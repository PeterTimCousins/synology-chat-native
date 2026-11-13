import SwiftUI

/// The same message, date divider and grouping composition in both timeline hosts.
struct NativeTimelineRowContent:View {
    let post:ChatPost
    let previous:ChatPost?
    @ObservedObject var model:NativeChatPreviewModel
#if DEBUG
    var fixtureEditor:NativeMessageEditorFixture? = nil
    var fixtureShowActions = false
#endif
    private var messageRow:NativeMessageRow {
        var row = NativeMessageRow(post:post,model:model,isContinuation:continuation)
#if DEBUG
        row.fixtureShowActions = fixtureShowActions
        if let fixtureEditor { return row.fixtureEditor(fixtureEditor) }
#endif
        return row
    }
    private var continuation:Bool { model.selectedChannel?.encrypted == false && NativeTimelineGrouping.isContinuation(post,after:previous,calendar:.current) }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if previous.map({ !Calendar.current.isDate($0.date,inSameDayAs:post.date) }) ?? true {
                NativeTimelineDayDivider(label:model.formattedDate(post.date,dateOnly:true))
            }
            messageRow
                .padding(.top,previous == nil || continuation ? 0 : 10)
                .id(post.id)
                .background(NativeTimelineRowMarker(postID:post.id,token:model.historyViewportToken).allowsHitTesting(false))
        }
    }
}
