import SwiftUI

struct NativeSearchFilters: View {
    @Binding var filters: ChatSearchFilters
    let users: [ChatUser]
    var nameFormat: ChatNameFormat = .nickname
    private var people: [ChatUser] { users.sorted { nameFormat.display($0).localizedCaseInsensitiveCompare(nameFormat.display($1)) == .orderedAscending } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:10) {
                GridRow {
                    NativeSearchChoice(label:"From",value:people.first(where:{$0.user_id==filters.authorID}).map { nameFormat.display($0) } ?? "Anyone") {
                        Button("Anyone") { filters.authorID = nil }
                        Divider()
                        ForEach(people,id:\.user_id) { person in Button(nameFormat.display(person)) { filters.authorID = person.user_id } }
                    }
                    NativeSearchChoice(label:"Mentions",value:people.first(where:{$0.user_id==filters.mentionID}).map { nameFormat.display($0) } ?? "Anyone") {
                        Button("Anyone") { filters.mentionID = nil }
                        Divider()
                        ForEach(people,id:\.user_id) { person in Button(nameFormat.display(person)) { filters.mentionID = person.user_id } }
                    }
                }
                GridRow {
                    NativeSearchChoice(label:"Type",value:filters.content.label) {
                        ForEach(ChatSearchFilters.Content.allCases) { item in Button(item.label) { filters.content = item } }
                    }
                    NativeSearchChoice(label:"Has",value:filters.attribute.label) {
                        ForEach(ChatSearchFilters.Attribute.allCases) { item in Button(item.label) { filters.attribute = item } }
                    }
                }
                GridRow {
                    HStack { Text("File extension"); TextField("e.g. pdf",text:$filters.fileType).textFieldStyle(.roundedBorder).accessibilityLabel("File extension filter") }
                    Button("Clear filters") { filters = .init() }.buttonStyle(.plain).foregroundColor(filters.isEmpty ? NativeChatColors.muted.opacity(0.5) : NativeChatColors.green).disabled(filters.isEmpty)
                }
            }
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:6) {
                    Toggle("From date",isOn:Binding(get:{filters.after != nil},set:{ filters.after = $0 ? Date() : nil }))
                    if filters.after != nil { DatePicker("Start date",selection:Binding(get:{filters.after ?? Date()},set:{filters.after=$0}),displayedComponents:.date).labelsHidden().accessibilityLabel("Start date") }
                }
                VStack(alignment:.leading,spacing:6) {
                    Toggle("Through date",isOn:Binding(get:{filters.before != nil},set:{ filters.before = $0 ? Date() : nil }))
                    if filters.before != nil { DatePicker("End date",selection:Binding(get:{filters.before ?? Date()},set:{filters.before=$0}),displayedComponents:.date).labelsHidden().accessibilityLabel("End date") }
                }
                Spacer()
            }
            Text("Dates use " + TimeZone.current.identifier + ".").font(.caption).foregroundColor(NativeChatColors.muted)
        }.font(.system(size:12)).padding(.top,10)
    }
}

private struct NativeSearchChoice<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        Menu(content:content) {
            Text(label + "  " + value).font(.system(size:12,weight:.medium)).lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize(horizontal:false,vertical:true)
            .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).padding(.vertical,8)
            .background(NativeChatColors.elevated).clipShape(RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(NativeChatColors.separator))
            .accessibilityLabel(label + " filter").accessibilityValue(value)
    }
}
