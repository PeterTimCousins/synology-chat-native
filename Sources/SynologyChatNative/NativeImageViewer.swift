import AppKit
import SwiftUI

struct NativeImageViewer: View {
    @ObservedObject var model: NativeChatPreviewModel
    var didJumpToSource: (() -> Void)? = nil
    var sourceContextLabel:String = "Search result"
    @State private var zoom = NativeImageViewerZoom()
    @State private var viewport = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @Environment(\.displayScale) private var displayScale
    @State private var paused = false
    @State private var applicationActive = NSApp.isActive
    @State private var viewerVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo").foregroundColor(NativeChatColors.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.imageViewerPost.map(model.attachmentName) ?? "Image")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(model.imageViewerPosition ?? 0) of \(model.imageViewerCount) loaded images · \(model.imageViewerOriginal ? "Full size" : "Preview")")
                        .font(.caption).foregroundColor(NativeChatColors.muted)
                    if model.searchImageOwner != nil,let post = model.imageViewerPost,let channel = model.channels.first(where:{ $0.id == post.channel_id }) {
                        Text(sourceContextLabel + " · " + model.title(channel)).font(.caption).foregroundColor(NativeChatColors.muted)
                    }
                }
                Spacer(minLength: 8)
                if !model.imageViewerOriginal {Button("Load original") {zoom.fit();model.viewOriginalImage()}.disabled(model.imageViewerLoading).help("Load the original image for full-resolution viewing")}
                if model.imageViewerFrameCount > 1 {Button(paused ? "Play" : "Pause") {paused.toggle()}.accessibilityLabel(paused ? "Play animated image" : "Pause animated image")}

                Button("Show message") { if model.jumpFromImageViewer() { didJumpToSource?() } }.disabled(model.imageViewerPost == nil)
                Button { model.closeImageViewer() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close image").keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
            Divider().overlay(NativeChatColors.separator)
            ZStack {
                Color.black.opacity(0.2)
                if let image = model.imageViewerImage {
                    GeometryReader { geometry in
                        let gestureZoom = zoom.magnified(magnification,imageSize:image.size,viewport:geometry.size,displayScale:displayScale)
                        let size = gestureZoom.layoutSize(imageSize:image.size,viewport:geometry.size,displayScale:displayScale)
                        ScrollView([.horizontal, .vertical]) {
                            NativeImageRasterView(image:image,playing:model.imageViewerFrameCount > 1 && !paused && applicationActive,label:model.imageViewerPost.map(model.attachmentName) ?? "Image attachment")
                                .frame(width: size.width, height: size.height)
                                .onTapGesture(count:2) { zoom.toggleActualSize() }
                                .help("Pinch to zoom. Double-click the image to switch between Fit and 100%.")
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                                .accessibilityLabel(model.imageViewerPost.map(model.attachmentName) ?? "Image attachment")
                        }
                        .onAppear { viewport = geometry.size }
                        .onChange(of:geometry.size) { viewport = $0 }
                        .simultaneousGesture(MagnificationGesture()
                            .updating($magnification) { value,state,_ in state = value }
                            .onEnded { value in
                                // Navigation, lock or replacement can retire a gesture's image.
                                guard viewerVisible,applicationActive,model.imageViewerImage === image else { return }
                                zoom = zoom.magnified(value,imageSize:image.size,viewport:geometry.size,displayScale:displayScale)
                            })
                        .id(model.imageViewerPost?.id)
                    }
                } else if model.imageViewerLoading {
                    ProgressView("Loading image…")
                } else if let error = model.imageViewerError {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark").font(.system(size: 30))
                        Text(error).foregroundColor(NativeChatColors.muted).multilineTextAlignment(.center)
                        Button("Try again") { model.retryViewerImage() }.buttonStyle(NativeSendButtonStyle())
                    }.padding(30)
                }
            }
            Divider().overlay(NativeChatColors.separator)
            zoomToolbar
            if model.imageHistoryLoading { ProgressView("Finding more images…").controlSize(.small).padding(8) }
            if let error = model.imageHistoryError {
                HStack { Text(error).font(.caption).foregroundColor(.orange);Button("Try loading images again") { model.retryImageHistory() } }.padding(8)
            }
            HStack(spacing: 10) {
                Button { model.moveViewerImage(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous image").disabled(!model.canViewPreviousImage || model.imageHistoryLoading).keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.moveViewerImage(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next image").disabled(!model.canViewNextImage || model.imageHistoryLoading).keyboardShortcut(.rightArrow, modifiers: [])
                if let post = model.imageViewerPost {
                    Text(model.messageText(post)).font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(2)
                    Spacer(minLength: 8)
                    if model.downloading.contains(post.id) {
                        ProgressView().controlSize(.small)
                        Button("Cancel save") { model.cancelDownload(postID: post.id) }
                    } else {
                        Button("Save original…") { Task { await model.saveAttachment(post) } }
                        Button("Save & open…") {
                            Task { await model.saveAttachment(post, openAfterSaving: { NSWorkspace.shared.open($0) }) }
                        }.help("Save the original file, then open it in its default app")
                    }
                }
            }.buttonStyle(NativeToolbarButtonStyle()).padding(16)
        }.frame(minWidth: 640, idealWidth: 900, maxWidth: 1000, minHeight: 520, idealHeight: 650, maxHeight: 780)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
            .onChange(of: model.imageViewerPost?.id) { _ in zoom.fit();paused = reduceMotion }
            .background(NativeImageViewerKeysView(enabled:viewerVisible && model.imageViewerImage != nil,action:handleImageKey))
            .onAppear {viewerVisible = true;paused = reduceMotion;applicationActive = NSApp.isActive}
            .onDisappear {viewerVisible = false}
            .onChange(of:reduceMotion) {paused = $0}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in applicationActive = true}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) {_ in applicationActive = false}
    }


    private func handleImageKey(_ action: NativeImageViewerKeys.Action) {
        switch action {
        case .zoomIn: zoom.step(1,imageSize:imageSize,viewport:viewport,displayScale:displayScale)
        case .zoomOut: zoom.step(-1,imageSize:imageSize,viewport:viewport,displayScale:displayScale)
        case .fit: zoom.fit()
        case .actualSize: zoom.actualSize()
        }
    }

    private var imageSize: CGSize { model.imageViewerImage?.size ?? .zero }
    private var zoomFraction: CGFloat {
        zoom.magnified(magnification,imageSize:imageSize,viewport:viewport,displayScale:displayScale)
            .fraction(imageSize:imageSize,viewport:viewport,displayScale:displayScale)
    }
    private var zoomToolbar: some View {
        HStack(spacing: 10) {
            Button { zoom.step(-1,imageSize:imageSize,viewport:viewport,displayScale:displayScale) } label: { Image(systemName:"minus.magnifyingglass") }
                .accessibilityLabel("Zoom image out")
                .help("Zoom image out (Control–Command–Minus)")
                .disabled(zoom.next(-1,imageSize:imageSize,viewport:viewport,displayScale:displayScale) == nil)
            Text(zoomFraction < 0.01 ? "<1%" : "\(Int((zoomFraction * 100).rounded()))%")
                .font(.system(size:12,weight:.medium,design:.monospaced)).frame(minWidth:46)
                .accessibilityLabel("Image zoom \(Int((zoomFraction * 100).rounded())) percent")
            Button { zoom.step(1,imageSize:imageSize,viewport:viewport,displayScale:displayScale) } label: { Image(systemName:"plus.magnifyingglass") }
                .accessibilityLabel("Zoom image in")
                .help("Zoom image in (Control–Command–Plus or Equals)")
                .disabled(zoom.next(1,imageSize:imageSize,viewport:viewport,displayScale:displayScale) == nil)
            Divider().frame(height:18)
            Button("Fit") { zoom.fit() }.disabled(zoom.isFit)
                .help("Fit image to the window (Control–Command–0)")
            Button("100%") { zoom.actualSize() }.disabled(zoom.mode == .percentage(1))
                .accessibilityLabel("Actual image size")
                .help("One image pixel per display pixel (Control–Command–1)")
            Spacer(minLength:8)
            Text(model.imageViewerOriginal ? "Original image" : "Preview image")
                .font(.caption).foregroundColor(NativeChatColors.muted)
        }.buttonStyle(NativeToolbarButtonStyle()).padding(.horizontal,16).padding(.vertical,8)
            .disabled(model.imageViewerImage == nil)
    }
}
