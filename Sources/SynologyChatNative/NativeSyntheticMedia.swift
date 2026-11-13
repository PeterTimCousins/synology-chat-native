#if DEBUG
import AppKit
import AVFoundation

enum NativeSyntheticMedia {
    static func wave() -> Data {
        let rate = 22050,count = rate * 3
        var data = Data()
        func ascii(_ text:String) { data.append(contentsOf:text.utf8) }
        func le<T:FixedWidthInteger>(_ value:T) { var value = value.littleEndian;withUnsafeBytes(of:&value) { data.append(contentsOf:$0) } }
        ascii("RIFF");le(UInt32(36+count*2));ascii("WAVEfmt ");le(UInt32(16));le(UInt16(1));le(UInt16(1))
        le(UInt32(rate));le(UInt32(rate*2));le(UInt16(2));le(UInt16(16));ascii("data");le(UInt32(count*2))
        for sample in 0..<count { le(Int16(sin(Double(sample)*2*Double.pi*440/Double(rate))*1800)) }
        return data
    }
    static func video(to url:URL) async throws {
        let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:180])
        guard writer.canAdd(input) else { throw ChatAPIError.invalidResponse };writer.add(input)
        guard writer.startWriting() else { throw ChatAPIError.invalidResponse };writer.startSession(atSourceTime:.zero)
        do {
            let deadline = Date().addingTimeInterval(15)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData {
                    guard Date() < deadline,writer.status == .writing else { throw ChatAPIError.invalidResponse }
                    try await Task.sleep(nanoseconds:1_000_000)
                }
                try Task.checkCancellation()
                var buffer:CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32ARGB,nil,&buffer) == kCVReturnSuccess,let buffer else { throw ChatAPIError.invalidResponse }
                CVPixelBufferLockBaseAddress(buffer,[])
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self),stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<180 { for x in 0..<320 {
                    let i = y*stride+x*4;bytes[i] = 255
                    let mint = x < (frame+1)*320/30
                    bytes[i+1] = mint ? 113 : 71;bytes[i+2] = mint ? 210 : 56;bytes[i+3] = mint ? 183 : 87
                } }
                CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:10)) else { throw ChatAPIError.invalidResponse }
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
            guard writer.status == .completed else { throw ChatAPIError.invalidResponse }
        } catch { writer.cancelWriting();throw error }
    }
    static func files(in folder:URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let audio = folder.appendingPathComponent("native-audio-preview.wav"),video = folder.appendingPathComponent("native-video-preview.mp4")
        do { try wave().write(to:audio);try await self.video(to:video);return [audio,video] }
        catch { try? FileManager.default.removeItem(at:folder);throw error }
    }
}
#endif
