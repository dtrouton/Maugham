import AppKit
import CoreGraphics

/// Real image files for the publishing tests: since staging sniffs every
/// figure (`FigureImageResolver.openingProblem`), a fixture must open as what
/// its extension says. `seed` varies the pixels, so two images hash apart.
enum TestImageBytes {

    static func png(seed: Int = 0, side: Int = 8) throws -> Data {
        try bitmap(seed: seed, side: side).representation(using: .png, properties: [:])
            .unwrap("PNG")
    }

    static func jpeg(seed: Int = 0, side: Int = 8) throws -> Data {
        try bitmap(seed: seed, side: side).representation(using: .jpeg, properties: [:])
            .unwrap("JPEG")
    }

    static func gif(seed: Int = 0, side: Int = 8) throws -> Data {
        try bitmap(seed: seed, side: side).representation(using: .gif, properties: [:])
            .unwrap("GIF")
    }

    /// A one-page PDF; `encrypted` locks it with a user password.
    static func pdf(encrypted: Bool = false) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let auxiliary: [CFString: Any] = encrypted
            ? [kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner"]
            : [:]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, auxiliary as CFDictionary)
        else { throw Failure(what: "PDF") }
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func svg() -> Data {
        Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#.utf8)
    }

    struct Failure: Error { let what: String }

    private static func bitmap(seed: Int, side: Int) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure(what: "bitmap") }
        for y in 0..<side {
            for x in 0..<side {
                let value = CGFloat((x * 31 + y * 17 + seed * 53) % 256) / 255
                rep.setColor(NSColor(deviceRed: value, green: 1 - value, blue: 0.5, alpha: 1),
                             atX: x, y: y)
            }
        }
        return rep
    }
}

private extension Optional where Wrapped == Data {
    func unwrap(_ what: String) throws -> Data {
        guard let self else { throw TestImageBytes.Failure(what: what) }
        return self
    }
}
