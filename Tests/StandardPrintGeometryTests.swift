import Foundation
import CoreGraphics

@main struct StandardPrintGeometryTests {
    static func main() {
        assert(PhotoPrintSize.one.isID && PhotoPrintSize.two.isID)
        assert(!PhotoPrintSize.three.isID && !PhotoPrintSize.six.isID)
        assert(PhotoPrintSize.three.defaultPaper == .pocketThree)
        assert(PhotoPrintSize.five.defaultPaper == .five)
        assert(PhotoPrintSize.six.defaultPaper == .six)
        assert(PhotoPrintSize.one.defaultPaper == .six)
        assert(StandardPrintGeometry.pixels(PaperSize.six.millimeters) == CGSize(width: 1200, height: 1800))
        assert(StandardPrintGeometry.pixels(PaperSize.xiaomiSix.millimeters) == CGSize(width: 1181, height: 1748))
        assert(PhotoPrintSize.one.millimeters == CGSize(width: 25, height: 35))
        assert(PhotoPrintSize.two.millimeters == CGSize(width: 35, height: 49))
        assert(StandardPrintGeometry.cells(paper: PaperSize.xiaomiSix.millimeters, photo: PhotoPrintSize.one.millimeters!).count == 12)
        assert(StandardPrintGeometry.cells(paper: PaperSize.xiaomiSix.millimeters, photo: PhotoPrintSize.six.millimeters!).isEmpty)
        assert(StandardPrintGeometry.cells(paper: PaperSize.six.millimeters, photo: PhotoPrintSize.six.millimeters!).count == 1)
        var combinations = 0
        for paper in PaperSize.allCases {
            for photo in PhotoPrintSize.allCases {
                guard let size = photo.millimeters else { continue }
                for landscape in [false, true] {
                    let p = paper.millimeters
                    let bounds = landscape ? CGSize(width: p.height, height: p.width) : p
                    for rotated in [false, true] {
                        let s = rotated ? CGSize(width: size.height, height: size.width) : size
                        let cells = StandardPrintGeometry.cells(paper: bounds, photo: s)
                        for (i, cell) in cells.enumerated() {
                            assert(cell.size == s, "Photo must never shrink")
                            assert(cell.minX >= -0.001 && cell.minY >= -0.001)
                            assert(cell.maxX <= bounds.width + 0.001 && cell.maxY <= bounds.height + 0.001)
                            for other in cells.dropFirst(i + 1) { assert(!cell.intersects(other)) }
                        }
                        combinations += 1
                    }
                }
            }
        }
        print("PASS: dimensions, exact fit, overflow rejection and \(combinations) paper/photo/orientation combinations")
    }
}
