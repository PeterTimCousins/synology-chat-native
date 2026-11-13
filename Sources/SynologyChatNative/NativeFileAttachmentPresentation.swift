import Foundation

/// Labels are descriptive only. File extensions never grant preview capability.
struct NativeFileAttachmentPresentation {
    let symbol: String
    let typeLabel: String
    let sizeLabel: String?
    var metadata: String { [typeLabel,sizeLabel].compactMap { $0 }.joined(separator:" · ") }

    init(filename:String,isImage:Bool,size:Int64?) {
        let ext = (filename as NSString).pathExtension.lowercased()
        if isImage {
            symbol = "photo";typeLabel = "Image"
        } else if let kind = NativeDocumentKind.forFilename(filename) {
            switch kind {
            case .pdf: symbol = "doc.richtext";typeLabel = "PDF document"
            case .text: symbol = "doc.text";typeLabel = "Text document"
            case .audio: symbol = "waveform";typeLabel = "Audio"
            case .video: symbol = "film";typeLabel = "Video"
            case .quickLook:
                if ["xls","xlsx","ods"].contains(ext) { symbol = "tablecells";typeLabel = "Spreadsheet" }
                else if ["ppt","pptx","odp"].contains(ext) { symbol = "rectangle.on.rectangle";typeLabel = "Presentation" }
                else { symbol = "doc.richtext";typeLabel = "Document" }
            }
        } else if ["zip","7z","rar","gz","tar","tgz","bz2","xz"].contains(ext) {
            symbol = "doc.zipper";typeLabel = "Archive"
        } else if ["xls","xlsx","numbers","ods"].contains(ext) {
            symbol = "tablecells";typeLabel = "Spreadsheet"
        } else if ["doc","docx","rtf","pages","odt"].contains(ext) {
            symbol = "doc.richtext";typeLabel = "Document"
        } else {
            symbol = "doc"
            let simple = !ext.isEmpty && ext.utf8.count <= 10 && ext.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            typeLabel = simple ? ext.uppercased() + " file" : "File"
        }
        sizeLabel = size.flatMap { $0 >= 0 ? ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) : nil }
    }
}
