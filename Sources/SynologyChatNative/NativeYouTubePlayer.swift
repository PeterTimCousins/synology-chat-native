import AppKit
import SwiftUI
import WebKit

/// A provider player is created only after the message's explicit, revalidated
/// play action. It never shares the NAS client's credentials or persistent data.
struct NativeYouTubePlayerSheet:View {
    let video:ChatYouTubeVideo
    @State private var revision = UUID()
    @State private var failure:String?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"play.rectangle.fill").font(.system(size:24)).foregroundColor(NativeChatColors.green)
                VStack(alignment:.leading,spacing:3) {
                    Text("YouTube").font(.system(size:19,weight:.bold))
                    Text("Video preview").font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button("Open YouTube") { NSWorkspace.shared.open(video.watchURL) }.buttonStyle(NativeToolbarButtonStyle())
                Button { dismiss() } label: { Image(systemName:"xmark") }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Close video").keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider().overlay(NativeChatColors.separator)
            NativeYouTubeWebView(video:video,failure:$failure).id(revision)
                .frame(minWidth:640,minHeight:360).background(Color.black)
            Divider().overlay(NativeChatColors.separator)
            HStack(spacing:12) {
                if let failure {
                    Label(failure,systemImage:"exclamationmark.circle").foregroundColor(.orange)
                    Spacer()
                    Button("Retry") { self.failure = nil;revision = UUID() }.buttonStyle(NativeToolbarButtonStyle())
                } else {
                    Text("Use the YouTube controls to play. If this video cannot play here, open it on YouTube.")
                        .foregroundColor(NativeChatColors.muted)
                    Spacer()
                }
            }.font(.callout).padding(16)
        }.frame(width:820,height:570).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance()
    }
}

enum NativeYouTubePlayerPolicy {
    static var referrer:URL { URL(string:"https://"+(Bundle.main.bundleIdentifier ?? "com.costwisegroup.synology-chat-native.api").lowercased())! }
    static func request(for video:ChatYouTubeVideo)->URLRequest {
        var request = URLRequest(url:video.embedURL,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:30)
        request.setValue(referrer.absoluteString,forHTTPHeaderField:"Referer")
        return request
    }
    static func allowsNavigation(_ url:URL,video:ChatYouTubeVideo,isMainFrame:Bool)->Bool {
        if !isMainFrame,url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https",url.user == nil,url.password == nil,url.port == nil || url.port == 443,
              ["www.youtube-nocookie.com","youtube-nocookie.com"].contains(url.host?.lowercased() ?? ""),
              url.path == "/embed/"+video.id else { return false }
        return true
    }
}

struct NativeYouTubeWebView:NSViewRepresentable {
    let video:ChatYouTubeVideo
    @Binding var failure:String?
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.processPool = WKProcessPool()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate = context.coordinator;view.uiDelegate = context.coordinator
        view.setAccessibilityLabel("YouTube video player")
        view.load(NativeYouTubePlayerPolicy.request(for:video))
        return view
    }
    func updateNSView(_ view:WKWebView,context:Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ view:WKWebView,coordinator:Coordinator) {
        coordinator.retired = true
        view.stopLoading();view.navigationDelegate = nil;view.uiDelegate = nil
        // Replacing the document destroys its media elements and stops playback.
        view.loadHTMLString("",baseURL:nil)
    }
    @MainActor final class Coordinator:NSObject,WKNavigationDelegate,WKUIDelegate {
        var parent:NativeYouTubeWebView
        var retired = false
        init(_ parent:NativeYouTubeWebView) { self.parent = parent }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            guard !retired,let url = action.request.url,action.targetFrame != nil,
                  NativeYouTubePlayerPolicy.allowsNavigation(url,video:parent.video,isMainFrame:action.targetFrame?.isMainFrame == true) else {
                decisionHandler(.cancel);return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView:WKWebView,decidePolicyFor response:WKNavigationResponse,decisionHandler:@escaping(WKNavigationResponsePolicy)->Void) {
            decisionHandler(!retired && response.canShowMIMEType ? .allow : .cancel)
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { failed(error) }
        func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {
            guard !retired else { return };parent.failure = "The video player stopped. Try again or open YouTube."
        }
        private func failed(_ error:Error) {
            guard !retired,(error as NSError).code != NSURLErrorCancelled else { return }
            parent.failure = "Could not load the video. Try again or open YouTube."
        }
        func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? { nil }
        func webView(_ webView:WKWebView,requestMediaCapturePermissionFor origin:WKSecurityOrigin,initiatedByFrame frame:WKFrameInfo,type:WKMediaCaptureType,decisionHandler:@escaping(WKPermissionDecision)->Void) { decisionHandler(.deny) }
    }
}
