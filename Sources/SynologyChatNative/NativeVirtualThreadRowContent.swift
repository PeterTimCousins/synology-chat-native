import SwiftUI

/// The existing thread's real message composition, hosted by the native
/// viewport. Root identity is separate from reply identity in the geometry map.
struct NativeVirtualThreadRowContent:View {
    let post:ChatPost
    let previous:ChatPost?
    let root:ChatPost?
    @ObservedObject var model:NativeChatPreviewModel
    var isRoot = false
#if DEBUG
    var fixtureEditor:NativeMessageEditorFixture? = nil
    var fixtureShowActions = false
#endif
    private var continuation:Bool {
        !isRoot && model.selectedChannel?.encrypted == false && NativeTimelineGrouping.isContinuation(post,after:previous,calendar:.current)
    }
    private var messageRow:NativeMessageRow {
        var row = NativeMessageRow(post:post,model:model,showsReplyAction:false,isContinuation:continuation)
#if DEBUG
        row.fixtureShowActions = fixtureShowActions
        if let fixtureEditor { return row.fixtureEditor(fixtureEditor) }
#endif
        return row
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if !isRoot,let date = previous?.date ?? root?.date,!Calendar.current.isDate(date,inSameDayAs:post.date) {
                NativeTimelineDayDivider(label:model.formattedDate(post.date,dateOnly:true))
            }
            messageRow
                .padding(.top,isRoot || previous == nil || continuation ? 0 : 14)
                .id(post.id)
                .background(NativeTimelineRowMarker(postID:post.id,token:model.nativeThreadViewportToken).allowsHitTesting(false))
        }
    }
}
