import Foundation
import UIKit

/// Run through Tools/test-photo-composition.sh. Uses UIKit directly, with no app
/// lifecycle, cameras, photo library, or printing. Fixtures stay in a temp folder.
@main
struct PhotoCompositionTests {
    private struct Marker {
        let name: String
        let rect: CGRect
        let rgb: (UInt8, UInt8, UInt8)

        var color: UIColor {
            UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                    blue: CGFloat(rgb.2) / 255, alpha: 1)
        }
    }

    private struct Fixture {
        let name: String
        let size: CGSize

        // Full-length edge bands detect crops and decoration entering the photo
        // window, including its corners. Top/bottom bands own the four corners.
        var markers: [Marker] {
            let w = size.width, h = size.height, t = min(w, h) * 0.035
            return [
                Marker(name: "top", rect: CGRect(x: 0, y: 0, width: w, height: t), rgb: (255, 0, 255)),
                Marker(name: "bottom", rect: CGRect(x: 0, y: h - t, width: w, height: t), rgb: (0, 255, 0)),
                Marker(name: "left", rect: CGRect(x: 0, y: t, width: t, height: h - 2 * t), rgb: (0, 0, 255)),
                Marker(name: "right", rect: CGRect(x: w - t, y: t, width: t, height: h - 2 * t), rgb: (255, 128, 0))
            ]
        }

        func image() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(white: 0.35, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                for marker in markers {
                    marker.color.setFill()
                    context.fill(marker.rect)
                }
            }
        }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: UIImage) throws {
            guard let cg = image.cgImage else { throw TestError.message("Image has no CGImage") }
            let width = cg.width, height = cg.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(
                    data: storage.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else { return false }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw TestError.message("Cannot read rendered pixels") }
            self.width = width
            self.height = height
            bytes = rgba
        }

        func fraction(matching rgb: (UInt8, UInt8, UInt8), in rect: CGRect) -> Double {
            let x0 = max(0, Int(ceil(rect.minX))), y0 = max(0, Int(ceil(rect.minY)))
            let x1 = min(width, Int(floor(rect.maxX))), y1 = min(height, Int(floor(rect.maxY)))
            guard x1 > x0, y1 > y0 else { return 0 }
            var matching = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = (y * width + x) * 4
                    // Permit interpolation and colour-management rounding, not
                    // another frame colour or a replacement grey background.
                    if abs(Int(bytes[p]) - Int(rgb.0)) <= 25,
                       abs(Int(bytes[p + 1]) - Int(rgb.1)) <= 25,
                       abs(Int(bytes[p + 2]) - Int(rgb.2)) <= 25 {
                        matching += 1
                    }
                }
            }
            return Double(matching) / Double((x1 - x0) * (y1 - y0))
        }
    }

    private enum TestError: Error { case message(String) }
    private static var failures: [String] = []
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    private static func save(_ image: UIImage, name: String, folder: URL) throws {
        guard let data = image.pngData() else { throw TestError.message("Cannot encode \(name)") }
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private static func photoBounds(fixture: Fixture, style: PhotoStyle, canvas: CGSize) -> CGRect {
        let opening = PrintLayoutRenderer.photoRect(canvasSize: canvas, style: style)
        let scale = min(opening.width / fixture.size.width, opening.height / fixture.size.height)
        let size = CGSize(width: fixture.size.width * scale, height: fixture.size.height * scale)
        return CGRect(x: opening.midX - size.width / 2, y: opening.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    private static func checkOpening(_ opening: CGRect, canvas: CGSize, label: String) {
        check(opening.width > 0 && opening.height > 0 && abs(opening.width / opening.height - 1.5) < 0.000001,
              "\(label): physical photo window must be 3:2, got \(opening.size)")
        check(opening.minX >= 0 && opening.minY >= 0 && opening.maxX <= canvas.width && opening.maxY <= canvas.height,
              "\(label): photo window must stay inside the canvas")
        check(abs(opening.midX - canvas.width / 2) < 0.001 && abs(opening.midY - canvas.height / 2) < 0.001,
              "\(label): photo window must be centred")
    }

    private static func edgeFractions(fixture: Fixture, image: UIImage, bounds: CGRect) throws -> [Double] {
        let pixels = try Pixels(image)
        let sx = bounds.width / fixture.size.width, sy = bounds.height / fixture.size.height
        return fixture.markers.map { marker in
            let r = marker.rect.insetBy(dx: 1, dy: 1)
            let target = CGRect(x: bounds.minX + r.minX * sx, y: bounds.minY + r.minY * sy,
                                width: r.width * sx, height: r.height * sy)
            return pixels.fraction(matching: marker.rgb, in: target)
        }
    }

    static func main() {
        do { try run() }
        catch { failures.append("Harness: \(error)") }
        if failures.isEmpty {
            print("PASS: \(checks) composition checks; 3:2 windows, full edge bands preserved in final composites, no 3:2 letterboxing")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("FAILED: \(failures.count) of \(checks) checks\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestError.message("Usage: PhotoCompositionTests <temporary-output-directory>")
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for template in WeddingTemplate.curated {
            if let name = template.assetName {
                guard UIImage(named: name) != nil else {
                    throw TestError.message("Missing frame asset \(name); refusing an undecorated false pass")
                }
            }
        }

        let fixtures = [
            Fixture(name: "3x2", size: CGSize(width: 900, height: 600)),
            Fixture(name: "4x3", size: CGSize(width: 800, height: 600)),
            Fixture(name: "16x9", size: CGSize(width: 960, height: 540)),
            Fixture(name: "portrait", size: CGSize(width: 600, height: 900))
        ]
        check(PhotoStyle().placement == .fit, "Default photo placement must preserve the full image")
        var contactImages: [(String, UIImage)] = []
        for fixture in fixtures {
            let source = fixture.image()
            try save(source, name: "source-\(fixture.name)", folder: folder)
            let sourceEdges = try edgeFractions(fixture: fixture, image: source, bounds: CGRect(origin: .zero, size: fixture.size))
            check(sourceEdges.allSatisfy { $0 >= 0.99 }, "\(fixture.name): fixture pixel reader must detect all four source markers")

            // Ordinary print sizes must not silently centre-crop, even with filters.
            for printSize in PhotoPrintSize.allCases where !printSize.isID {
                for filter in [PhotoFilter.original, .warm, .mono] {
                    var style = PhotoStyle()
                    style.printSize = printSize
                    style.filter = filter
                    let edited = PrintLayoutRenderer.edited(source, style: style)
                    check(edited.size == fixture.size, "\(fixture.name)/\(printSize)/\(filter): edited must retain source dimensions")
                }
            }

            for (index, template) in WeddingTemplate.curated.enumerated() {
                var style = PhotoStyle()
                style.weddingTemplate = template
                style.direction = .landscape
                style.mijiaPaperMode = .sixInch
                style.placement = .fit
                let rendered = PrintLayoutRenderer.render(image: source, layout: .full, style: style)
                check(rendered.size == CGSize(width: 1800, height: 1200), "\(template)/\(fixture.name): six-inch canvas dimensions")
                let opening = PrintLayoutRenderer.photoRect(canvasSize: rendered.size, style: style)
                checkOpening(opening, canvas: rendered.size, label: "\(template)/\(fixture.name)")
                if template != .none {
                    check(sameRect(opening, CGRect(x: 180, y: 120, width: 1440, height: 960)),
                          "\(template): curated frame opening must use the shared 10%/80% layout")
                }
                // Default titles are part of the template contract. Arbitrary
                // user-positioned captions may intentionally overlap a photo.
                for caption in style.resolvedCaptions {
                    let captionRect = PrintLayoutRenderer.captionRect(caption, canvasSize: rendered.size)
                    check(!captionRect.intersects(opening), "\(template): default caption enters the photo window: \(caption.text)")
                }
                let bounds = photoBounds(fixture: fixture, style: style, canvas: rendered.size)
                if fixture.name == "3x2" {
                    check(sameRect(bounds, opening), "\(template): a 3:2 source must fill the window without letterboxing")
                }
                let photoLayer = PrintLayoutRenderer.render(image: source, layout: .full, style: style, includeDecorations: false)
                let geometry = try edgeFractions(fixture: fixture, image: photoLayer, bounds: bounds)
                for (marker, fraction) in zip(fixture.markers, geometry) {
                    check(fraction >= 0.99, "\(template.rawValue)/\(fixture.name) \(marker.name): photo layer cropped an edge")
                }
                let visibility = try edgeFractions(fixture: fixture, image: rendered, bounds: bounds)
                for (marker, fraction) in zip(fixture.markers, visibility) {
                    // Artwork and default captions stay outside the opening.
                    // Do not allow the previous partial visibility from art.
                    check(fraction >= 0.99, "\(template.rawValue)/\(fixture.name) \(marker.name) final edge obscured: \(Int(fraction * 100))% visible")
                }
                try save(rendered, name: "\(index)-\(fixture.name)-fit", folder: folder)
                contactImages.append(("\(template.rawValue) · \(fixture.name)", rendered))
            }

            // No-border mode and quarter-turns retain the complete source too.
            for turn in 0..<4 {
                var style = PhotoStyle()
                style.quarterTurns = turn
                let edited = PrintLayoutRenderer.photoWithoutPaper(image: source, style: style)
                let expected = turn % 2 == 0 ? fixture.size : CGSize(width: fixture.size.height, height: fixture.size.width)
                check(edited.size == expected, "\(fixture.name): rotation \(turn) must only swap dimensions")
            }
            var borderless = PhotoStyle()
            borderless.borderInset = 0
            borderless.direction = .landscape
            borderless.mijiaPaperMode = .sixInch
            let fit = PrintLayoutRenderer.render(image: source, layout: .full, style: borderless)
            let fractions = try edgeFractions(fixture: fixture, image: fit,
                                             bounds: photoBounds(fixture: fixture, style: borderless, canvas: fit.size))
            check(fractions.allSatisfy { $0 >= 0.99 }, "\(fixture.name): borderless fit must retain all four edges")
        }

        // The plain frame must preserve 3:2 too. Equal pixel insets on both
        // axes would change the ratio and add letterboxing, even for 3:2 input.
        let standard = fixtures[0]
        let standardSource = standard.image()
        let canvas = CGSize(width: 1800, height: 1200)
        var plainImages: [(String, UIImage)] = []
        for (colorIndex, color) in PhotoFrame.allCases.enumerated() {
            var previousWidth = canvas.width + 1
            for inset: CGFloat in [0, 45, 54] {
                var style = PhotoStyle()
                style.frame = color
                style.borderInset = inset
                style.direction = .landscape
                style.mijiaPaperMode = .sixInch
                style.captions = []
                let opening = PrintLayoutRenderer.photoRect(canvasSize: canvas, style: style)
                let label = "plain/\(color.rawValue)/inset \(inset)"
                checkOpening(opening, canvas: canvas, label: label)
                check(opening.width < previousWidth, "\(label): increasing border inset must reduce the window")
                previousWidth = opening.width
                if inset == 0 {
                    check(sameRect(opening, CGRect(origin: .zero, size: canvas)), "\(label): no border must use the full canvas")
                }
                let bounds = photoBounds(fixture: standard, style: style, canvas: canvas)
                check(sameRect(bounds, opening), "\(label): 3:2 source must have no internal letterbox")
                let rendered = PrintLayoutRenderer.render(image: standardSource, layout: .full, style: style)
                let visibility = try edgeFractions(fixture: standard, image: rendered, bounds: opening)
                for (marker, fraction) in zip(standard.markers, visibility) {
                    check(fraction >= 0.99, "\(label): \(marker.name) final edge must remain complete")
                }
                try save(rendered, name: "plain-\(colorIndex)-inset-\(Int(inset))", folder: folder)
                plainImages.append(("\(color.rawValue) · \(Int(inset))", rendered))
            }
        }

        // Negative control: explicit fill is allowed to crop. This must fail the
        // same edge check, proving that it detects the original failure mode.
        let wide = fixtures[2]
        var fill = PhotoStyle()
        fill.direction = .landscape
        fill.mijiaPaperMode = .sixInch
        fill.borderInset = 0
        fill.placement = .fill
        let cropped = PrintLayoutRenderer.render(image: wide.image(), layout: .full, style: fill)
        let negative = try edgeFractions(fixture: wide, image: cropped,
                                        bounds: photoBounds(fixture: wide, style: fill, canvas: cropped.size))
        check(negative.contains { $0 < 0.10 }, "Explicit fill negative control must lose at least one edge")
        try save(cropped, name: "negative-control-16x9-fill", folder: folder)

        // ID photos deliberately retain their 25x35 / 35x49 mm centre crop and
        // exact physical cells; removing ordinary aspect crop must not alter it.
        for (printSize, millimeters) in [(PhotoPrintSize.one, CGSize(width: 25, height: 35)), (.two, CGSize(width: 35, height: 49))] {
            for fixture in fixtures {
                var style = PhotoStyle()
                style.printSize = printSize
                let edited = PrintLayoutRenderer.edited(fixture.image(), style: style)
                check(abs(edited.size.width / edited.size.height - millimeters.width / millimeters.height) < 0.004,
                      "\(printSize)/\(fixture.name): ID crop ratio must remain \(millimeters)")
            }
            for turn in 0..<4 {
                var style = PhotoStyle()
                style.printSize = printSize
                style.quarterTurns = turn
                style.direction = .landscape
                let expected = turn % 2 == 0 ? millimeters : CGSize(width: millimeters.height, height: millimeters.width)
                let cells = PrintLayoutRenderer.standardCells(style: style) ?? []
                check(!cells.isEmpty && cells.allSatisfy { $0.size == expected }, "\(printSize)/turn \(turn): ID cells must retain exact millimetres")
            }
        }
        try save(contactSheet(contactImages), name: "contact-sheet", folder: folder)
        try save(contactSheet(plainImages), name: "plain-contact-sheet", folder: folder)
        print("Rendered fixtures: \(folder.path)")
    }

    private static func contactSheet(_ images: [(String, UIImage)]) -> UIImage {
        let columns = 4, cellWidth = 450, cellHeight = 330
        let rows = (images.count + columns - 1) / columns
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: columns * cellWidth, height: rows * cellHeight), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: columns * cellWidth, height: rows * cellHeight))
            for (index, item) in images.enumerated() {
                let x = (index % columns) * cellWidth, y = (index / columns) * cellHeight
                item.1.draw(in: CGRect(x: x, y: y + 26, width: cellWidth, height: 300))
                (item.0 as NSString).draw(at: CGPoint(x: x + 8, y: y + 4), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black
                ])
            }
        }
    }
}
