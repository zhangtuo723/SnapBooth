import UIKit
import CoreImage

enum PhotoAspect: String, CaseIterable {
    case original = "原始", square = "1:1", portrait = "3:4", film = "2:3", wide = "16:9"
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .portrait: return 3 / 4
        case .film: return 2 / 3
        case .wide: return 16 / 9
        }
    }
}
enum PhotoFilter: String, CaseIterable {
    case original = "原片", warm = "暖阳", cool = "清透", fade = "胶片", mono = "黑白", instant = "复古"
    var ciName: String? {
        switch self {
        case .original: return nil
        case .warm, .cool: return "CITemperatureAndTint"
        case .fade: return "CIPhotoEffectFade"
        case .mono: return "CIPhotoEffectNoir"
        case .instant: return "CIPhotoEffectInstant"
        }
    }
}
enum PhotoFrame: String, CaseIterable {
    case white = "留白", cream = "奶油", pink = "樱粉", champagne = "香槟", wine = "酒红", sage = "鼠尾草", black = "暗房"
    var color: UIColor {
        switch self {
        case .white: return .white
        case .cream: return UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1)
        case .pink: return UIColor(red: 1, green: 0.85, blue: 0.87, alpha: 1)
        case .champagne: return UIColor(red: 0.88, green: 0.78, blue: 0.60, alpha: 1)
        case .wine: return UIColor(red: 0.40, green: 0.035, blue: 0.075, alpha: 1)
        case .sage: return UIColor(red: 0.63, green: 0.70, blue: 0.60, alpha: 1)
        case .black: return UIColor(white: 0.10, alpha: 1)
        }
    }
}
enum WeddingTemplate: String, CaseIterable {
    case none = "纯净"
    case redGold = "红金囍宴"
    case garden = "花园誓言"
    case film = "甜蜜胶片"
    case hearts = "心动拍立得"
    case champagne = "香槟金线"
    case botanical = "森系花环"
    case pearl = "珍珠白纱"
    case ribbon = "缎带誓言"
    case nightGold = "鎏金夜宴"
    case chinese = "中式窗棂"
    case minimal = "极简落款"
}
enum PaperDirection: String, CaseIterable { case auto = "自动", portrait = "竖向", landscape = "横向" }
enum PhotoPlacement: String, CaseIterable { case fit = "完整留白", fill = "裁切铺满" }
struct PhotoStyle {
    var aspect: PhotoAspect = .original
    var filter: PhotoFilter = .original
    var frame: PhotoFrame = .white
    var intensity: Float = 1
    var paper: PaperSize = .six
    var direction: PaperDirection = .auto
    var placement: PhotoPlacement = .fit
    var printSize: PhotoPrintSize = .auto
    var quarterTurns: Int = 0
    var mijiaPaperMode: MijiaPaperMode?
    var borderInset: CGFloat = 45
    var weddingTemplate: WeddingTemplate = .none
}

enum PhotoLayout: String, CaseIterable, Identifiable {
    case full = "满版照片"
    case grid = "四宫格"
    case strips = "双联照片条"

    var id: String { rawValue }
}

enum PrintLayoutRenderer {
    private static let ciContext = CIContext()
    static func edited(_ image: UIImage, style: PhotoStyle) -> UIImage {
        // Normalize orientation before cropping and filtering.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard var cg = normalized.cgImage else { return image }
        let standardRatio = style.printSize.isID ? style.printSize.millimeters.map { $0.width / $0.height } : nil
        if let ratio = standardRatio ?? style.aspect.ratio {
            let width = CGFloat(cg.width), height = CGFloat(cg.height)
            let cropW = min(width, height * ratio)
            let cropH = min(height, width / ratio)
            if let cropped = cg.cropping(to: CGRect(x: (width - cropW) / 2, y: (height - cropH) / 2, width: cropW, height: cropH).integral) { cg = cropped }
        }
        guard let name = style.filter.ciName, let filter = CIFilter(name: name) else { return UIImage(cgImage: cg) }
        let input = CIImage(cgImage: cg)
        filter.setValue(input, forKey: kCIInputImageKey)
        if style.filter == .warm || style.filter == .cool {
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: style.filter == .warm ? 8000 : 4800, y: 0), forKey: "inputTargetNeutral")
        }
        guard let output = filter.outputImage,
              let filtered = ciContext.createCGImage(output, from: input.extent) else { return UIImage(cgImage: cg) }
        return UIGraphicsImageRenderer(size: CGSize(width: cg.width, height: cg.height), format: format).image { _ in
            UIImage(cgImage: cg).draw(at: .zero)
            UIImage(cgImage: filtered).draw(at: .zero, blendMode: .normal, alpha: CGFloat(style.intensity))
        }
    }
    static func canvasSize(imageSize: CGSize, style: PhotoStyle) -> CGSize {
        if let mijiaMode = style.mijiaPaperMode {
            switch mijiaMode {
            case .sixInch:
                return style.direction == .landscape
                    ? CGSize(width: 1800, height: 1200)
                    : CGSize(width: 1200, height: 1800)
            }
        }
        let inches = style.paper.millimeters
        let landscape = style.direction == .landscape || (style.direction == .auto && imageSize.width > imageSize.height)
        return StandardPrintGeometry.pixels(CGSize(width: landscape ? inches.height : inches.width,
                      height: landscape ? inches.width : inches.height))
    }

    static func standardCells(style: PhotoStyle) -> [CGRect]? {
        guard style.printSize.isID, var size = style.printSize.millimeters else { return nil }
        if style.quarterTurns % 2 != 0 { size = CGSize(width: size.height, height: size.width) }
        var paper = style.paper.millimeters
        if style.direction == .landscape || (style.direction == .auto && size.width > size.height) {
            paper = CGSize(width: paper.height, height: paper.width)
        }
        return StandardPrintGeometry.cells(paper: paper, photo: size)
    }

    /// Photo edits only; the receiving app owns paper size, borders and templates.
    static func photoWithoutPaper(image: UIImage, style: PhotoStyle) -> UIImage {
        var image = edited(image, style: style)
        if style.quarterTurns % 4 != 0 {
            let source = image
            let swap = style.quarterTurns % 2 != 0
            let size = swap ? CGSize(width: source.size.height, height: source.size.width) : source.size
            let rotationFormat = UIGraphicsImageRendererFormat()
            rotationFormat.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: rotationFormat).image { context in
                context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
                context.cgContext.rotate(by: CGFloat(style.quarterTurns) * .pi / 2)
                source.draw(in: CGRect(x: -source.size.width / 2, y: -source.size.height / 2, width: source.size.width, height: source.size.height))
            }
        }
        return image
    }

    static func render(image: UIImage, layout: PhotoLayout, style: PhotoStyle = PhotoStyle(), previewScale: CGFloat = 1) -> UIImage {
        let image = photoWithoutPaper(image: image, style: style)
        let canvasSize = canvasSize(imageSize: image.size, style: style)
        let format = UIGraphicsImageRendererFormat()
        format.scale = previewScale < 1 ? min(previewScale, 720 / max(canvasSize.width, canvasSize.height)) : 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            style.frame.color.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            if let cells = standardCells(style: style) {
                var fixedStyle = style
                fixedStyle.placement = .fill
                for cell in cells {
                    let p = StandardPrintGeometry.pixelsPerMM
                    let rect = CGRect(x: cell.minX * p, y: cell.minY * p, width: cell.width * p, height: cell.height * p)
                    drawPhoto(image, in: rect, style: fixedStyle)
                    // Thin trim guides identify the exact finished photo boundary.
                    context.cgContext.setStrokeColor(UIColor.gray.cgColor)
                    context.cgContext.setLineWidth(0.5)
                    context.cgContext.stroke(rect)
                }
                return
            }

            switch layout {
            case .full:
                drawPhoto(
                    image,
                    in: CGRect(origin: .zero, size: canvasSize).insetBy(dx: style.borderInset, dy: style.borderInset),
                    style: style
                )
            case .grid:
                let gap: CGFloat = 24
                let margin: CGFloat = 45
                let width = (canvasSize.width - margin * 2 - gap) / 2
                let height = (canvasSize.height - margin * 2 - gap) / 2
                for row in 0..<2 {
                    for column in 0..<2 {
                        let rect = CGRect(
                            x: margin + CGFloat(column) * (width + gap),
                            y: margin + CGFloat(row) * (height + gap),
                            width: width,
                            height: height
                        )
                        drawPhoto(image, in: rect, style: style)
                    }
                }
            case .strips:
                let stripWidth: CGFloat = (canvasSize.width - 180) / 2
                let cellHeight: CGFloat = (canvasSize.height - 270) / 3
                let margin: CGFloat = 75
                for column in 0..<2 {
                    let x = margin + CGFloat(column) * (stripWidth + 30)
                    for row in 0..<3 {
                        let rect = CGRect(x: x, y: 75 + CGFloat(row) * (cellHeight + 20), width: stripWidth, height: cellHeight)
                        drawPhoto(image, in: rect, style: style)
                    }
                    drawBrand(in: CGRect(x: x, y: canvasSize.height - 120, width: stripWidth, height: 70), dark: style.frame == .black)
                }
            }
            drawWeddingTemplate(style.weddingTemplate, canvasSize: canvasSize, context: context.cgContext)
        }
    }

    static func applyingTemplate(_ template: WeddingTemplate, to image: UIImage, previewScale: CGFloat = 1) -> UIImage {
        guard template != .none else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = previewScale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            drawWeddingTemplate(template, canvasSize: image.size, context: context.cgContext)
        }
    }

    private static func drawWeddingTemplate(_ template: WeddingTemplate, canvasSize: CGSize, context: CGContext) {
        guard template != .none else { return }
        let width = canvasSize.width
        let height = canvasSize.height
        let unit = min(width, height) / 1200
        context.saveGState()

        func draw(_ text: String, rect: CGRect, size: CGFloat, color: UIColor, weight: UIFont.Weight = .semibold, alignment: NSTextAlignment = .center) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            text.draw(in: rect, withAttributes: [
                .font: UIFont.systemFont(ofSize: size * unit, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ])
        }

        func drawLeaf(center: CGPoint, size: CGSize, angle: CGFloat, color: UIColor) {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            color.setFill()
            context.fillEllipse(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }

        func strokeInset(_ inset: CGFloat, radius: CGFloat, color: UIColor, lineWidth: CGFloat) {
            color.setStroke()
            context.setLineWidth(lineWidth * unit)
            let rect = CGRect(x: inset * unit, y: inset * unit, width: width - inset * 2 * unit, height: height - inset * 2 * unit)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: radius * unit).cgPath)
            context.strokePath()
        }

        switch template {
        case .none:
            break
        case .redGold:
            let red = UIColor(red: 0.58, green: 0.015, blue: 0.025, alpha: 0.96)
            let gold = UIColor(red: 0.96, green: 0.76, blue: 0.35, alpha: 1)
            red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 118 * unit))
            context.fill(CGRect(x: 0, y: height - 118 * unit, width: width, height: 118 * unit))
            gold.setStroke()
            context.setLineWidth(5 * unit)
            context.stroke(CGRect(x: 28 * unit, y: 28 * unit, width: width - 56 * unit, height: height - 56 * unit))
            draw("囍", rect: CGRect(x: 48 * unit, y: 20 * unit, width: 110 * unit, height: 90 * unit), size: 64, color: gold, weight: .regular)
            draw("良辰 · 吉日", rect: CGRect(x: width - 360 * unit, y: 45 * unit, width: 300 * unit, height: 50 * unit), size: 28, color: gold, alignment: .right)
            draw("OUR WEDDING DAY", rect: CGRect(x: 60 * unit, y: height - 83 * unit, width: width - 120 * unit, height: 45 * unit), size: 26, color: gold)
        case .garden:
            let cream = UIColor(red: 0.99, green: 0.95, blue: 0.88, alpha: 0.94)
            let green = UIColor(red: 0.18, green: 0.38, blue: 0.24, alpha: 1)
            cream.setFill()
            context.fill(CGRect(x: 0, y: height - 142 * unit, width: width, height: 142 * unit))
            let petals = [UIColor(red: 0.95, green: 0.72, blue: 0.74, alpha: 0.95), UIColor(red: 0.96, green: 0.86, blue: 0.63, alpha: 0.95), UIColor.white]
            for cornerX in [CGFloat(38), width / unit - 176] {
                for index in 0..<9 {
                    petals[index % petals.count].setFill()
                    let x = (cornerX + CGFloat(index % 3) * 54) * unit
                    let y = (CGFloat(index / 3) * 42 + 25) * unit
                    context.fillEllipse(in: CGRect(x: x, y: y, width: 62 * unit, height: 62 * unit))
                }
            }
            draw("OUR FOREVER STARTS HERE", rect: CGRect(x: 190 * unit, y: height - 103 * unit, width: width - 380 * unit, height: 48 * unit), size: 28, color: green)
        case .film:
            UIColor(white: 0.04, alpha: 0.96).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 105 * unit))
            context.fill(CGRect(x: 0, y: height - 105 * unit, width: width, height: 105 * unit))
            UIColor(white: 0.88, alpha: 1).setFill()
            let holeWidth = 42 * unit
            let gap = 30 * unit
            var x = 24 * unit
            while x < width - holeWidth {
                context.fill(CGRect(x: x, y: 22 * unit, width: holeWidth, height: 23 * unit))
                context.fill(CGRect(x: x, y: height - 45 * unit, width: holeWidth, height: 23 * unit))
                x += holeWidth + gap
            }
            draw("LOVE STORY  ·  FRAME 01", rect: CGRect(x: 70 * unit, y: height - 91 * unit, width: width - 140 * unit, height: 42 * unit), size: 25, color: .white)
        case .hearts:
            let pink = UIColor(red: 0.95, green: 0.24, blue: 0.42, alpha: 0.96)
            let blush = UIColor(red: 1.0, green: 0.88, blue: 0.90, alpha: 0.96)
            context.setLineWidth(34 * unit)
            context.setStrokeColor(blush.cgColor)
            context.stroke(CGRect(x: 17 * unit, y: 17 * unit, width: width - 34 * unit, height: height - 34 * unit))
            draw("♥", rect: CGRect(x: 45 * unit, y: 30 * unit, width: 100 * unit, height: 90 * unit), size: 66, color: pink)
            draw("♥", rect: CGRect(x: width - 145 * unit, y: height - 120 * unit, width: 100 * unit, height: 90 * unit), size: 66, color: pink)
            let pill = CGRect(x: width / 2 - 205 * unit, y: height - 105 * unit, width: 410 * unit, height: 70 * unit)
            pink.setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 35 * unit).fill()
            draw("LOVE  ·  SWEET MOMENT", rect: CGRect(x: pill.minX, y: pill.minY + 15 * unit, width: pill.width, height: 42 * unit), size: 25, color: .white)
        case .champagne:
            let champagne = UIColor(red: 0.82, green: 0.64, blue: 0.33, alpha: 0.98)
            let ivory = UIColor(red: 1, green: 0.98, blue: 0.92, alpha: 0.88)
            strokeInset(34, radius: 12, color: champagne, lineWidth: 5)
            strokeInset(54, radius: 8, color: champagne.withAlphaComponent(0.6), lineWidth: 2)
            ivory.setFill()
            context.fill(CGRect(x: width / 2 - 325 * unit, y: height - 92 * unit, width: 650 * unit, height: 58 * unit))
            for side: CGFloat in [-1, 1] {
                let originX = side < 0 ? 74 * unit : width - 74 * unit
                context.setStrokeColor(champagne.cgColor)
                context.setLineWidth(3 * unit)
                context.move(to: CGPoint(x: originX, y: 60 * unit))
                context.addCurve(
                    to: CGPoint(x: originX + side * 165 * unit, y: 205 * unit),
                    control1: CGPoint(x: originX + side * 20 * unit, y: 135 * unit),
                    control2: CGPoint(x: originX + side * 120 * unit, y: 140 * unit)
                )
                context.strokePath()
            }
            draw("TOGETHER IS A BEAUTIFUL PLACE", rect: CGRect(x: width / 2 - 310 * unit, y: height - 80 * unit, width: 620 * unit, height: 42 * unit), size: 23, color: UIColor(red: 0.42, green: 0.31, blue: 0.14, alpha: 1))
        case .botanical:
            let sage = UIColor(red: 0.24, green: 0.43, blue: 0.32, alpha: 0.93)
            let pale = UIColor(red: 0.72, green: 0.80, blue: 0.67, alpha: 0.86)
            strokeInset(31, radius: 26, color: sage.withAlphaComponent(0.72), lineWidth: 4)
            for corner in 0..<4 {
                let right = corner % 2 == 1
                let bottom = corner >= 2
                let baseX = right ? width - 95 * unit : 95 * unit
                let baseY = bottom ? height - 86 * unit : 86 * unit
                for index in 0..<7 {
                    let distance = CGFloat(index) * 39 * unit
                    let x = baseX + (right ? -distance : distance)
                    let y = baseY + (bottom ? -distance * 0.34 : distance * 0.34)
                    drawLeaf(
                        center: CGPoint(x: x, y: y),
                        size: CGSize(width: 54 * unit, height: 25 * unit),
                        angle: (right ? -.pi / 5 : .pi / 5) + (bottom ? -.pi / 8 : .pi / 8),
                        color: index.isMultiple(of: 2) ? sage : pale
                    )
                }
            }
            let badge = CGRect(x: width / 2 - 185 * unit, y: height - 92 * unit, width: 370 * unit, height: 58 * unit)
            UIColor(red: 0.96, green: 0.95, blue: 0.87, alpha: 0.92).setFill()
            UIBezierPath(roundedRect: badge, cornerRadius: 29 * unit).fill()
            draw("OUR WEDDING DAY", rect: CGRect(x: badge.minX, y: badge.minY + 13 * unit, width: badge.width, height: 37 * unit), size: 23, color: sage)
        case .pearl:
            let pearl = UIColor(red: 1, green: 0.99, blue: 0.96, alpha: 0.95)
            let silver = UIColor(red: 0.80, green: 0.78, blue: 0.73, alpha: 0.95)
            context.setStrokeColor(pearl.cgColor)
            context.setLineWidth(20 * unit)
            context.stroke(CGRect(x: 18 * unit, y: 18 * unit, width: width - 36 * unit, height: height - 36 * unit))
            pearl.setFill()
            let pearlSize = 17 * unit
            var x = 54 * unit
            while x < width - 54 * unit {
                context.fillEllipse(in: CGRect(x: x, y: 38 * unit, width: pearlSize, height: pearlSize))
                context.fillEllipse(in: CGRect(x: x, y: height - 55 * unit, width: pearlSize, height: pearlSize))
                x += 43 * unit
            }
            silver.setStroke()
            context.setLineWidth(2 * unit)
            context.strokeEllipse(in: CGRect(x: width / 2 - 72 * unit, y: 44 * unit, width: 90 * unit, height: 90 * unit))
            context.strokeEllipse(in: CGRect(x: width / 2 - 18 * unit, y: 44 * unit, width: 90 * unit, height: 90 * unit))
            draw("JUST MARRIED", rect: CGRect(x: width / 2 - 210 * unit, y: height - 108 * unit, width: 420 * unit, height: 45 * unit), size: 24, color: UIColor(white: 0.25, alpha: 0.9))
        case .ribbon:
            let burgundy = UIColor(red: 0.45, green: 0.025, blue: 0.08, alpha: 0.94)
            let roseGold = UIColor(red: 0.92, green: 0.68, blue: 0.56, alpha: 1)
            strokeInset(30, radius: 6, color: roseGold, lineWidth: 4)
            let ribbonRect = CGRect(x: width / 2 - 350 * unit, y: height - 126 * unit, width: 700 * unit, height: 90 * unit)
            burgundy.setFill()
            UIBezierPath(roundedRect: ribbonRect, cornerRadius: 16 * unit).fill()
            context.setStrokeColor(roseGold.cgColor)
            context.setLineWidth(3 * unit)
            context.move(to: CGPoint(x: ribbonRect.minX + 36 * unit, y: ribbonRect.midY))
            context.addLine(to: CGPoint(x: ribbonRect.maxX - 36 * unit, y: ribbonRect.midY))
            context.strokePath()
            draw("PROMISES  ·  LAUGHTER  ·  FOREVER", rect: CGRect(x: ribbonRect.minX + 42 * unit, y: ribbonRect.minY + 20 * unit, width: ribbonRect.width - 84 * unit, height: 48 * unit), size: 22, color: .white)
        case .nightGold:
            let black = UIColor(white: 0.025, alpha: 0.88)
            let gold = UIColor(red: 0.94, green: 0.71, blue: 0.27, alpha: 1)
            black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 82 * unit))
            context.fill(CGRect(x: 0, y: height - 82 * unit, width: width, height: 82 * unit))
            strokeInset(25, radius: 4, color: gold, lineWidth: 3)
            strokeInset(42, radius: 2, color: gold.withAlphaComponent(0.55), lineWidth: 1.5)
            draw("✦", rect: CGRect(x: 54 * unit, y: 14 * unit, width: 74 * unit, height: 56 * unit), size: 37, color: gold)
            draw("THE NIGHT WE SAID YES", rect: CGRect(x: 150 * unit, y: 24 * unit, width: width - 300 * unit, height: 40 * unit), size: 24, color: gold)
            draw("MEMORIES IN GOLD", rect: CGRect(x: 150 * unit, y: height - 61 * unit, width: width - 300 * unit, height: 38 * unit), size: 21, color: gold)
        case .chinese:
            let red = UIColor(red: 0.68, green: 0.015, blue: 0.025, alpha: 0.96)
            let gold = UIColor(red: 0.96, green: 0.76, blue: 0.32, alpha: 1)
            context.setStrokeColor(red.cgColor)
            context.setLineWidth(14 * unit)
            let length = 165 * unit
            let inset = 34 * unit
            for (x, y, sx, sy) in [(inset, inset, 1.0, 1.0), (width - inset, inset, -1.0, 1.0), (inset, height - inset, 1.0, -1.0), (width - inset, height - inset, -1.0, -1.0)] {
                context.move(to: CGPoint(x: x, y: y + CGFloat(sy) * length))
                context.addLine(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + CGFloat(sx) * length, y: y))
                context.strokePath()
            }
            let seal = CGRect(x: width - 176 * unit, y: height - 176 * unit, width: 126 * unit, height: 126 * unit)
            red.setFill()
            UIBezierPath(roundedRect: seal, cornerRadius: 16 * unit).fill()
            draw("囍", rect: CGRect(x: seal.minX, y: seal.minY + 18 * unit, width: seal.width, height: 90 * unit), size: 66, color: gold, weight: .regular)
            draw("百年好合", rect: CGRect(x: 62 * unit, y: height - 105 * unit, width: 300 * unit, height: 58 * unit), size: 30, color: red, alignment: .left)
        case .minimal:
            let white = UIColor.white.withAlphaComponent(0.92)
            strokeInset(42, radius: 0, color: white, lineWidth: 3)
            let topLabel = CGRect(x: width / 2 - 195 * unit, y: 43 * unit, width: 390 * unit, height: 54 * unit)
            UIColor(white: 0.08, alpha: 0.62).setFill()
            UIBezierPath(roundedRect: topLabel, cornerRadius: 27 * unit).fill()
            draw("US  ·  TODAY  ·  ALWAYS", rect: CGRect(x: topLabel.minX, y: topLabel.minY + 13 * unit, width: topLabel.width, height: 36 * unit), size: 21, color: .white)
            let date = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            draw(date, rect: CGRect(x: width - 310 * unit, y: height - 92 * unit, width: 245 * unit, height: 44 * unit), size: 22, color: white, alignment: .right)
        }
        context.restoreGState()
    }

    private static func drawPhoto(_ image: UIImage, in cell: CGRect, style: PhotoStyle) {
        let rect = cell
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let scale = style.placement == .fill ? max(rect.width / sourceSize.width, rect.height / sourceSize.height) : min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.clip(to: rect)
        image.draw(in: drawRect)
        context?.restoreGState()
    }

    private static func drawBrand(in rect: CGRect, dark: Bool) {
        let text = "SNAPBOOTH  •  \(Date.now.formatted(date: .numeric, time: .omitted))"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 25, weight: .semibold),
            .foregroundColor: dark ? UIColor.white : UIColor.black,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}
