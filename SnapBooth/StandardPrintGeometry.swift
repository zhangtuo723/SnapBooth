import Foundation
import CoreGraphics

enum PaperSize: String, CaseIterable {
    case six = "6寸相纸 · 102×152 mm"
    case five = "5寸相纸 · 89×127 mm"
    case seven = "7寸相纸 · 127×178 mm"
    case xiaomiSix = "小米桌面6寸 · 100×148 mm"
    case xiaomiThree = "小米桌面3寸 · 86×102 mm"
    case xiaomiSquare = "米家方形即贴相纸"
    case pocketThree = "小米口袋3寸 · 50×76 mm"
    var millimeters: CGSize {
        switch self {
        case .six: return CGSize(width: 101.6, height: 152.4)
        case .five: return CGSize(width: 88.9, height: 127)
        case .seven: return CGSize(width: 127, height: 177.8)
        case .xiaomiSix: return CGSize(width: 100, height: 148)
        case .xiaomiThree: return CGSize(width: 86, height: 102)
        case .xiaomiSquare: return CGSize(width: 101.6, height: 101.6)
        case .pocketThree: return CGSize(width: 50, height: 76)
        }
    }
}

enum MijiaPaperMode {
    case sixInch
}
enum PhotoPrintSize: String, CaseIterable {
    case auto = "自由", one = "1寸", two = "2寸", three = "3寸", five = "5寸", six = "6寸"
    var isID: Bool { self == .one || self == .two }
    var defaultPaper: PaperSize {
        switch self {
        case .three: return .pocketThree
        case .five: return .five
        default: return .six
        }
    }
    var millimeters: CGSize? {
        switch self {
        case .auto: return nil
        case .one: return CGSize(width: 25, height: 35)
        case .two: return CGSize(width: 35, height: 49)
        case .three: return CGSize(width: 50, height: 76)
        case .five: return CGSize(width: 88.9, height: 127)
        case .six: return CGSize(width: 101.6, height: 152.4)
        }
    }
    var detail: String {
        switch self {
        case .auto: return "自由画幅 · 使用下方排版"
        case .one: return "1寸 · 25×35 mm"
        case .two: return "2寸 · 35×49 mm"
        case .three: return "3寸 · 50×76 mm（口袋相纸）"
        case .five: return "5寸 · 89×127 mm（3.5×5英寸）"
        case .six: return "6寸 · 102×152 mm（4×6英寸）"
        }
    }
}

enum StandardPrintGeometry {
    static let pixelsPerMM: CGFloat = 300 / 25.4
    static func pixels(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * pixelsPerMM).rounded(), height: (size.height * pixelsPerMM).rounded())
    }
    /// Exact-size centered copies, with 2 mm gutters. Never scales a photo to fit.
    static func cells(paper: CGSize, photo: CGSize) -> [CGRect] {
        let gap: CGFloat = 2
        guard photo.width > 0, photo.height > 0 else { return [] }
        let columns = Int(floor((paper.width + gap + 0.0001) / (photo.width + gap)))
        let rows = Int(floor((paper.height + gap + 0.0001) / (photo.height + gap)))
        guard columns > 0, rows > 0 else { return [] }
        let x = (paper.width - CGFloat(columns) * photo.width - CGFloat(columns - 1) * gap) / 2
        let y = (paper.height - CGFloat(rows) * photo.height - CGFloat(rows - 1) * gap) / 2
        var result: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let left = x + CGFloat(col) * (photo.width + gap)
                let top = y + CGFloat(row) * (photo.height + gap)
                result.append(CGRect(x: left, y: top, width: photo.width, height: photo.height))
            }
        }
        return result
    }
}
