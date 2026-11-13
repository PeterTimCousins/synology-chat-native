import SwiftUI

struct NativeSearchSuggestions:View {
    let suggestions:[ChatSearchQuery.Suggestion]
    let selected:Int?
    let choose:(ChatSearchQuery.Suggestion)->Void
    private var groupCount:Int { Set(suggestions.map(\.group)).count }
    private var showsLimitHint:Bool { Dictionary(grouping:suggestions,by:\.group).values.contains { $0.count >= ChatSearchQuery.suggestionGroupLimit } }
    private var menuHeight:CGFloat {
        let allOperators = suggestions.allSatisfy { $0.group == "Search operators" }
        return min(CGFloat(suggestions.count)*36+CGFloat(groupCount)*25+12,allOperators ? 330 : 220)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:3) {
                        ForEach(Array(suggestions.enumerated()),id:\.element.id) { index,suggestion in
                            if index == 0 || suggestions[index-1].group != suggestion.group {
                                Text(suggestion.group).font(.system(size:10,weight:.semibold)).foregroundColor(NativeChatColors.muted).padding(.horizontal,10).padding(.top,index == 0 ? 6 : 12).padding(.bottom,3)
                            }
                            Button { choose(suggestion) } label: {
                                HStack(spacing:10) {
                                    Image(systemName:suggestion.symbol).font(.system(size:12)).foregroundColor(NativeChatColors.muted).frame(width:18)
                                    Text(suggestion.label).font(.system(size:12,weight:.medium)).lineLimit(1)
                                    if let explanation = suggestion.explanation { Text(explanation).font(.system(size:11)).foregroundColor(NativeChatColors.muted).lineLimit(1) }
                                    Spacer(minLength:4)
                                    if selected == index { Image(systemName:"return").font(.system(size:10)).foregroundColor(NativeChatColors.muted) }
                                }.padding(.horizontal,10).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(selected == index ? NativeChatColors.selected : Color.clear).clipShape(RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(suggestion.label).accessibilityHint(suggestion.explanation ?? "Insert search filter")
                                .accessibilityValue(selected == index ? "Selected" : "").accessibilityIdentifier("search-suggestion-"+suggestion.id).id(suggestion.id)
                        }
                    }.padding(6)
                }.frame(height:menuHeight)
                    .onAppear { if let selected,suggestions.indices.contains(selected) { proxy.scrollTo(suggestions[selected].id,anchor:.center) } }
                    .onChange(of:selected) { index in if let index,suggestions.indices.contains(index) { proxy.scrollTo(suggestions[index].id,anchor:.center) } }
            }
            if showsLimitHint { Text("Type more to narrow these matches.").font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,10).padding(.bottom,6) }
        }.background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
    }
}
