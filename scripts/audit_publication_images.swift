import Foundation
import Vision
import ImageIO

// Keep OCR local. The caller captures this JSON and reports only filenames and
// rule names, never the recognized private text.
var records: [[String: Any]] = []
do {
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "PublicationImage", code: 1)
        }
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw NSError(domain: "PublicationImage", code: 2)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            records.append([
                "path": path,
                "text": (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"),
                "metadata": String(describing: properties),
                "gps": properties[kCGImagePropertyGPSDictionary as String] != nil
            ])
        }
    }
    let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data("Image privacy inspection failed.\n".utf8))
    exit(1)
}
