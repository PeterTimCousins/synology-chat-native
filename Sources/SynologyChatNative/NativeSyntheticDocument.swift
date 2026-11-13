#if DEBUG
import AppKit
import PDFKit

enum NativeSyntheticDocument {
    static func data() throws -> Data {
        let pdf = PDFDocument()
        for number in 1...2 {
            let image = NSImage(size:NSSize(width:612,height:792),flipped:false) { rect in
                NSColor.white.setFill();rect.fill()
                let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:28,weight:.semibold),.foregroundColor:NSColor.black]
                ("Native document preview" as NSString).draw(at:NSPoint(x:48,y:680),withAttributes:attributes)
                ("Page \(number) of 2" as NSString).draw(at:NSPoint(x:48,y:625),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.darkGray])
                ("Synthetic test content. No private data." as NSString).draw(at:NSPoint(x:48,y:580),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.darkGray])
                NSColor(calibratedRed:0.28,green:0.22,blue:0.34,alpha:1).setFill();NSRect(x:48,y:390,width:516,height:100).fill()
                NSColor(calibratedRed:0.44,green:0.82,blue:0.72,alpha:1).setFill();NSRect(x:48,y:270,width:516,height:100).fill()
                return true
            }
            guard let page = PDFPage(image:image) else { throw ChatAPIError.invalidResponse };pdf.insert(page,at:pdf.pageCount)
        }
        guard let bytes = pdf.dataRepresentation() else { throw ChatAPIError.invalidResponse };return bytes
    }
}
#endif
