import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import PhotosUI
import UIKit

// MARK: - App Version Constant (Tự động đọc bởi GitHub Actions để đặt tên file .ipa)
let APP_VERSION = "2.3.0"

enum AppVersionHelper {
    static var displayString: String {
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? APP_VERSION
        let buildNum = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(shortVer) (Build \(buildNum))"
    }
}

// MARK: - App Entry Point
@main
struct BookSplitScannerApp: App {
    var body: some Scene {
        WindowGroup {
            VFlatMainContainerView()
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - Models & Enums

enum ReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight = "1 | 2 (Trái → Phải)"
    case rightToLeft = "2 | 1 (Phải → Trái)"

    var id: String { rawValue }
}

enum EnhancementFilter: String, CaseIterable, Identifiable {
    case cleanBook = "AI Cleanup (Trắng giấy & Khử bóng)"
    case blackAndWhite = "Đen trắng sắc nét"
    case original = "Ảnh gốc Camera"

    var id: String { rawValue }
    var shortName: String {
        switch self {
        case .cleanBook: return "AI Cleanup"
        case .blackAndWhite: return "Đen trắng"
        case .original: return "Ảnh gốc"
        }
    }
}

enum PageSideLabel: String {
    case left = "Trang 1 (Trái)"
    case right = "Trang 2 (Phải)"
    case full = "1 Trang"
}

enum RescanMode: Equatable {
    case normalAppend
    case replaceSinglePage(pageID: UUID)
    case replaceSpreadPair(pageID: UUID)
}

enum AutoCaptureStatus: Equatable {
    case manualOnly
    case noBookDetected
    case stabilizing(progress: CGFloat) // 0.0 -> 1.0 (Teal fill sweeping up when book is detected & still)
    case capturing
    case waitingForPageTurn // Sau khi chụp xong 1 lượt, chờ người dùng lật sang trang mới
}

enum AutoCaptureLightProfile: String, CaseIterable, Identifiable {
    case autoAdaptive = "Tự động theo ánh sáng"
    case lowLight = "Ưu tiên thiếu sáng"
    case normalLight = "Ưu tiên ánh sáng tốt"

    var id: String { rawValue }
}

enum CaptureTriggerSource: String {
    case manual = "manual"
    case auto = "auto"
}

struct AutoCaptureDiagnosticsSnapshot {
    let timestamp: Date
    let paperLevel: Double
    let paperRatio: Double
    let textTransitions: Int
    let motionScore: Double
    let quadShift: CGFloat
    let decision: String
}

struct ScannedBookPage: Identifiable, Equatable {
    let id: UUID
    let spreadGroupID: UUID
    var sourceSpreadImage: UIImage
    var processedImage: UIImage
    var sideLabel: PageSideLabel
    var splitRatio: CGFloat
    var gutterTrimRatio: CGFloat
    var filter: EnhancementFilter
    var removeFingersAtEdges: Bool
    var rotationDegrees: Int
    var recognizedText: String?

    init(
        id: UUID = UUID(),
        spreadGroupID: UUID = UUID(),
        sourceSpreadImage: UIImage,
        processedImage: UIImage,
        sideLabel: PageSideLabel,
        splitRatio: CGFloat = 0.5,
        gutterTrimRatio: CGFloat = 0.015,
        filter: EnhancementFilter = .cleanBook,
        removeFingersAtEdges: Bool = true,
        rotationDegrees: Int = 0,
        recognizedText: String? = nil
    ) {
        self.id = id
        self.spreadGroupID = spreadGroupID
        self.sourceSpreadImage = sourceSpreadImage
        self.processedImage = processedImage
        self.sideLabel = sideLabel
        self.splitRatio = splitRatio
        self.gutterTrimRatio = gutterTrimRatio
        self.filter = filter
        self.removeFingersAtEdges = removeFingersAtEdges
        self.rotationDegrees = rotationDegrees
        self.recognizedText = recognizedText
    }

    static func == (lhs: ScannedBookPage, rhs: ScannedBookPage) -> Bool {
        lhs.id == rhs.id &&
        lhs.spreadGroupID == rhs.spreadGroupID &&
        lhs.splitRatio == rhs.splitRatio &&
        lhs.gutterTrimRatio == rhs.gutterTrimRatio &&
        lhs.filter == rhs.filter &&
        lhs.removeFingersAtEdges == rhs.removeFingersAtEdges &&
        lhs.rotationDegrees == rhs.rotationDegrees &&
        lhs.recognizedText == rhs.recognizedText
    }
}

/// Khung chữ nhật chuẩn hóa [0...1] trong hệ tọa độ ngang của sách
struct NormalizedBookRect: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    static let defaultSpread = NormalizedBookRect(x: 0.07, y: 0.10, width: 0.86, height: 0.80)

    func interpolated(with target: NormalizedBookRect, alpha: CGFloat) -> NormalizedBookRect {
        NormalizedBookRect(
            x: x + (target.x - x) * alpha,
            y: y + (target.y - y) * alpha,
            width: width + (target.width - width) * alpha,
            height: height + (target.height - height) * alpha
        )
    }
}

/// 4 góc trang sách theo tọa độ Vision (chuẩn hóa 0...1, gốc dưới-trái) trên khung hình camera dọc.
/// Được ghi lại từ Preview ngay lúc chụp để làm "gợi ý" cắt & nắn phẳng khi ảnh chụp không tự dò được mép sách.
struct PageQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
    /// Tỷ lệ rộng/cao của khung hình nơi tìm được 4 góc (để chỉ dùng gợi ý khi ảnh chụp cùng khung nhìn)
    var sourceAspect: CGFloat

    init(_ obs: VNRectangleObservation, sourceAspect: CGFloat) {
        topLeft = obs.topLeft
        topRight = obs.topRight
        bottomLeft = obs.bottomLeft
        bottomRight = obs.bottomRight
        self.sourceAspect = sourceAspect
    }

    var center: CGPoint {
        CGPoint(
            x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4.0,
            y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4.0
        )
    }

    /// Độ dịch chuyển lớn nhất của 1 góc so với khung khác (để đo độ ổn định khi cầm tay)
    func maxCornerDistance(to other: PageQuad) -> CGFloat {
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        return max(
            dist(topLeft, other.topLeft), dist(topRight, other.topRight),
            dist(bottomLeft, other.bottomLeft), dist(bottomRight, other.bottomRight)
        )
    }

    /// Nới rộng khung ra ngoài một chút để không cắt mất chữ sát mép (giữ lại phần rìa trang)
    func expanded(by ratio: CGFloat) -> PageQuad {
        let c = center
        func push(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: min(1.0, max(0.0, c.x + (p.x - c.x) * (1.0 + ratio))),
                y: min(1.0, max(0.0, c.y + (p.y - c.y) * (1.0 + ratio)))
            )
        }
        var q = self
        q.topLeft = push(topLeft)
        q.topRight = push(topRight)
        q.bottomLeft = push(bottomLeft)
        q.bottomRight = push(bottomRight)
        return q
    }
}

// MARK: - Book Spine Detection, Perspective Flattening, Finger Cleanup & OCR Engine

final class BookSpineProcessor {
    static let shared = BookSpineProcessor()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func normalizeOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Đảm bảo ảnh trang đôi luôn xoay nằm ngang đúng chiều đọc (Notch bên trái -> xoay ngược chiều kim đồng hồ 90°)
    func ensureLandscapeSpread(_ image: UIImage, isTwoPageMode: Bool, landscapeFlipped180: Bool = false) -> UIImage {
        let normalized = normalizeOrientation(image)
        return orientSpread(
            normalized,
            sourceIsPortrait: normalized.size.height > normalized.size.width * 1.02,
            isTwoPageMode: isTwoPageMode,
            landscapeFlipped180: landscapeFlipped180
        )
    }

    /// Xoay ảnh trang đôi dựa theo hướng của ẢNH CHỤP GỐC (không phải ảnh đã cắt),
    /// vì sau khi cắt sát trang sách, tỷ lệ khung có thể không còn phản ánh hướng cầm máy.
    func orientSpread(_ image: UIImage, sourceIsPortrait: Bool, isTwoPageMode: Bool, landscapeFlipped180: Bool) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard isTwoPageMode else { return normalized }
        if sourceIsPortrait {
            // Khi khóa màn hình dọc và cầm ngang máy (Notch bên trái), đỉnh ảnh nằm bên trái sách -> xoay 90° ngược chiều kim đồng hồ
            return rotate90Degrees(normalized, clockwise: landscapeFlipped180)
        } else if landscapeFlipped180 {
            let r1 = rotate90Degrees(normalized, clockwise: true)
            return rotate90Degrees(r1, clockwise: true)
        }
        return normalized
    }

    func rotate90Degrees(_ image: UIImage, clockwise: Bool) -> UIImage {
        let normalized = normalizeOrientation(image)
        let newSize = CGSize(width: normalized.size.height, height: normalized.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cgContext.rotate(by: clockwise ? (.pi / 2) : (-.pi / 2))
            normalized.draw(in: CGRect(
                x: -normalized.size.width / 2,
                y: -normalized.size.height / 2,
                width: normalized.size.width,
                height: normalized.size.height
            ))
        }
    }

    /// Chuẩn bị ảnh trang đôi/đơn từ ảnh chụp thô: cắt & nắn phẳng trang sách TRƯỚC, sau đó mới xoay ngang.
    /// `hint` là 4 góc trang sách đã thấy trên Preview ngay lúc chụp (nếu có).
    func prepareSpread(
        _ rawShot: UIImage,
        hint: PageQuad?,
        isTwoPageMode: Bool,
        landscapeFlipped180: Bool
    ) -> UIImage {
        let normalized = normalizeOrientation(rawShot)
        let flattened = autoCropAndFlattenBook(normalized, hint: hint)
        return orientSpread(
            flattened,
            sourceIsPortrait: normalized.size.height > normalized.size.width * 1.02,
            isTwoPageMode: isTwoPageMode,
            landscapeFlipped180: landscapeFlipped180
        )
    }

    /// Tự động phát hiện và nắn phẳng 4 góc trang sách bằng Vision + CIPerspectiveCorrection.
    /// Ảnh được chụp rộng (kèm phần rìa/nền bàn), bước này mới cắt lấy đúng trang sách:
    /// 1. Dò trang sách trên ảnh chụp độ phân giải cao (AI nhận diện tài liệu, rồi tới hình chữ nhật)
    /// 2. Nếu không dò được, dùng 4 góc đã thấy trên Preview lúc bấm chụp
    /// 3. Nếu vẫn không có, giữ nguyên ảnh gốc (người dùng chỉnh tay sau)
    func autoCropAndFlattenBook(_ image: UIImage, hint: PageQuad? = nil) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return normalized }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let imageAspect = w / max(1, h)

        var quad = detectPageQuad(in: cgImage)
        if quad == nil, let hint, abs(hint.sourceAspect - imageAspect) < 0.03 {
            quad = hint
        }
        guard let pageQuad = quad?.expanded(by: 0.025) else {
            return normalized
        }

        let ciImage = CIImage(cgImage: cgImage)
        let perspective = CIFilter.perspectiveCorrection()
        perspective.inputImage = ciImage
        perspective.topLeft = CGPoint(x: pageQuad.topLeft.x * w, y: pageQuad.topLeft.y * h)
        perspective.topRight = CGPoint(x: pageQuad.topRight.x * w, y: pageQuad.topRight.y * h)
        perspective.bottomLeft = CGPoint(x: pageQuad.bottomLeft.x * w, y: pageQuad.bottomLeft.y * h)
        perspective.bottomRight = CGPoint(x: pageQuad.bottomRight.x * w, y: pageQuad.bottomRight.y * h)

        guard let outputCI = perspective.outputImage,
              let renderedCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else {
            return normalized
        }
        return UIImage(cgImage: renderedCG, scale: 1.0, orientation: .up)
    }

    /// Dò 4 góc trang sách trên ảnh tĩnh. Bỏ qua kết quả quá nhỏ (dưới 15% diện tích ảnh).
    func detectPageQuad(in cgImage: CGImage) -> PageQuad? {
        let aspect = CGFloat(cgImage.width) / CGFloat(max(1, cgImage.height))

        let documentRequest = VNDetectDocumentSegmentationRequest()
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumAspectRatio = 0.3
        rectangleRequest.maximumAspectRatio = 1.0 // Vision chỉ nhận giá trị trong [0, 1]
        rectangleRequest.minimumSize = 0.3
        rectangleRequest.minimumConfidence = 0.5
        rectangleRequest.quadratureTolerance = 40
        rectangleRequest.maximumObservations = 4

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([documentRequest, rectangleRequest])

        func isLargeEnough(_ obs: VNRectangleObservation) -> Bool {
            obs.confidence >= 0.5 && obs.boundingBox.width * obs.boundingBox.height >= 0.15
        }

        if let doc = documentRequest.results?.first, isLargeEnough(doc) {
            return PageQuad(doc, sourceAspect: aspect)
        }
        let largest = (rectangleRequest.results ?? []).filter(isLargeEnough).max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        return largest.map { PageQuad($0, sourceAspect: aspect) }
    }

    /// Thuật toán tự động dò vị trí gáy sách (Spine Detection) trong vùng trung tâm [38% ... 62%]
    func detectSpineSplitRatio(in cgImage: CGImage) -> CGFloat {
        let analysisWidth = 240
        let analysisHeight = 200

        var pixels = [UInt8](repeating: 255, count: analysisWidth * analysisHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: &pixels,
            width: analysisWidth,
            height: analysisHeight,
            bitsPerComponent: 8,
            bytesPerRow: analysisWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0.5
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight))

        let minX = Int(Double(analysisWidth) * 0.38)
        let maxX = Int(Double(analysisWidth) * 0.62)
        let minY = Int(Double(analysisHeight) * 0.10)
        let maxY = Int(Double(analysisHeight) * 0.90)
        let rowCount = Double(max(1, maxY - minY))

        var columnMeanBrightness = [Double](repeating: 255.0, count: analysisWidth)
        var columnVerticalEdgeEnergy = [Double](repeating: 0.0, count: analysisWidth)

        for x in minX...maxX {
            var sumBrightness = 0.0
            var sumVerticalTransitions = 0.0
            for y in minY..<maxY {
                let idx = y * analysisWidth + x
                let val = Double(pixels[idx])
                sumBrightness += val
                if y > minY {
                    let prevVal = Double(pixels[(y - 1) * analysisWidth + x])
                    sumVerticalTransitions += abs(val - prevVal)
                }
            }
            columnMeanBrightness[x] = sumBrightness / rowCount
            columnVerticalEdgeEnergy[x] = sumVerticalTransitions / rowCount
        }

        var bestX = analysisWidth / 2
        var lowestScore = Double.greatestFiniteMagnitude
        let center = Double(analysisWidth) * 0.5

        for x in (minX + 2)...(maxX - 2) {
            var smoothBrightness = 0.0
            var smoothTextEnergy = 0.0
            for dx in -2...2 {
                smoothBrightness += columnMeanBrightness[x + dx]
                smoothTextEnergy += columnVerticalEdgeEnergy[x + dx]
            }
            smoothBrightness /= 5.0
            smoothTextEnergy /= 5.0

            let centerDistancePenalty = abs(Double(x) - center) / Double(analysisWidth) * 65.0
            let score = (smoothBrightness * 0.65) + (smoothTextEnergy * 1.45) + centerDistancePenalty

            if score < lowestScore {
                lowestScore = score
                bestX = x
            }
        }

        let detectedRatio = CGFloat(bestX) / CGFloat(analysisWidth)
        return min(max(detectedRatio, 0.40), 0.60)
    }

    /// Khử ngón tay giữ mép sách (Finger Removal) ở rìa ngoài cùng của trang sách
    func cleanOuterMarginFingers(_ image: UIImage) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return normalized }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 80, height > 80 else { return normalized }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            normalized.draw(in: CGRect(origin: .zero, size: size))
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor(white: 0.985, alpha: 1.0).cgColor)
            let borderX = CGFloat(width) * 0.015
            let borderY = CGFloat(height) * 0.014
            cgCtx.fill(CGRect(x: 0, y: 0, width: size.width, height: borderY))
            cgCtx.fill(CGRect(x: 0, y: size.height - borderY, width: size.width, height: borderY))
            cgCtx.fill(CGRect(x: 0, y: 0, width: borderX, height: size.height))
            cgCtx.fill(CGRect(x: size.width - borderX, y: 0, width: borderX, height: size.height))
        }
    }

    /// Áp dụng bộ lọc AI Cleanup (Làm trắng trang giấy, khử bóng rãnh gáy và tăng nét chữ)
    func applyEnhancement(
        _ image: UIImage,
        filter: EnhancementFilter,
        removeFingersAtEdges: Bool
    ) -> UIImage {
        var working = normalizeOrientation(image)
        if removeFingersAtEdges && filter != .original {
            working = cleanOuterMarginFingers(working)
        }
        guard filter != .original, let cgImage = working.cgImage else {
            return working
        }

        let ciImage = CIImage(cgImage: cgImage)
        var outputCI = ciImage

        switch filter {
        case .original:
            return working

        case .cleanBook:
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = outputCI
            shadowHighlight.shadowAmount = 0.68
            shadowHighlight.highlightAmount = 0.92
            if let shOut = shadowHighlight.outputImage {
                outputCI = shOut
            }

            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = outputCI
            colorControls.contrast = 1.34
            colorControls.brightness = 0.07
            colorControls.saturation = 0.72
            if let ccOut = colorControls.outputImage {
                outputCI = ccOut
            }

            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = outputCI
            unsharp.radius = 1.75
            unsharp.intensity = 0.82
            if let usOut = unsharp.outputImage {
                outputCI = usOut
            }

        case .blackAndWhite:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = outputCI
            if let noirOut = noir.outputImage {
                outputCI = noirOut
            }

            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = outputCI
            colorControls.contrast = 1.48
            colorControls.brightness = 0.09
            colorControls.saturation = 0.0
            if let ccOut = colorControls.outputImage {
                outputCI = ccOut
            }

            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = outputCI
            sharpen.sharpness = 0.65
            if let shOut = sharpen.outputImage {
                outputCI = shOut
            }
        }

        guard let renderedCG = ciContext.createCGImage(outputCI, from: ciImage.extent) else {
            return working
        }
        return UIImage(cgImage: renderedCG, scale: 1.0, orientation: .up)
    }

    /// Tách 1 ảnh chụp trang đôi thành 2 trang sách riêng biệt giống vFlat
    func processAndSplitCapturedShot(
        _ rawShot: UIImage,
        twoPageMode: Bool,
        readingDirection: ReadingDirection,
        enhancement: EnhancementFilter,
        gutterTrimRatio: CGFloat = 0.015,
        removeFingers: Bool = true,
        landscapeFlipped180: Bool = false,
        pageQuadHint: PageQuad? = nil
    ) -> [ScannedBookPage] {
        return autoreleasepool {
            let groupID = UUID()
            // Cắt & nắn phẳng trang sách từ ảnh chụp rộng, rồi xoay ngang đúng hướng cầm máy của chế độ 2 trang
            let spreadImage = prepareSpread(
                rawShot,
                hint: pageQuadHint,
                isTwoPageMode: twoPageMode,
                landscapeFlipped180: landscapeFlipped180
            )
            guard let cgImage = spreadImage.cgImage else { return [] }

            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)

            if !twoPageMode {
                let enhanced = applyEnhancement(
                    spreadImage,
                    filter: enhancement,
                    removeFingersAtEdges: removeFingers
                )
                return [
                    ScannedBookPage(
                        spreadGroupID: groupID,
                        sourceSpreadImage: spreadImage,
                        processedImage: enhanced,
                        sideLabel: .full,
                        splitRatio: 0.5,
                        gutterTrimRatio: 0.0,
                        filter: enhancement,
                        removeFingersAtEdges: removeFingers
                    )
                ]
            }

            let splitRatio = detectSpineSplitRatio(in: cgImage)
            let splitX = width * splitRatio
            let trimPx = width * min(max(gutterTrimRatio, 0.0), 0.06)

            let leftWidth = max(1.0, splitX - trimPx)
            let rightStartX = min(width - 1.0, splitX + trimPx)
            let rightWidth = max(1.0, width - rightStartX)

            let leftRect = CGRect(x: 0, y: 0, width: leftWidth, height: height).integral
            let rightRect = CGRect(x: rightStartX, y: 0, width: rightWidth, height: height).integral

            var leftPage: ScannedBookPage?
            var rightPage: ScannedBookPage?

            if let leftCG = cgImage.cropping(to: leftRect) {
                let rawLeft = UIImage(cgImage: leftCG, scale: 1.0, orientation: .up)
                let enhancedLeft = applyEnhancement(
                    rawLeft,
                    filter: enhancement,
                    removeFingersAtEdges: removeFingers
                )
                leftPage = ScannedBookPage(
                    spreadGroupID: groupID,
                    sourceSpreadImage: spreadImage,
                    processedImage: enhancedLeft,
                    sideLabel: .left,
                    splitRatio: splitRatio,
                    gutterTrimRatio: gutterTrimRatio,
                    filter: enhancement,
                    removeFingersAtEdges: removeFingers
                )
            }

            if let rightCG = cgImage.cropping(to: rightRect) {
                let rawRight = UIImage(cgImage: rightCG, scale: 1.0, orientation: .up)
                let enhancedRight = applyEnhancement(
                    rawRight,
                    filter: enhancement,
                    removeFingersAtEdges: removeFingers
                )
                rightPage = ScannedBookPage(
                    spreadGroupID: groupID,
                    sourceSpreadImage: spreadImage,
                    processedImage: enhancedRight,
                    sideLabel: .right,
                    splitRatio: splitRatio,
                    gutterTrimRatio: gutterTrimRatio,
                    filter: enhancement,
                    removeFingersAtEdges: removeFingers
                )
            }

            var ordered: [ScannedBookPage] = []
            switch readingDirection {
            case .leftToRight:
                if let leftPage { ordered.append(leftPage) }
                if let rightPage { ordered.append(rightPage) }
            case .rightToLeft:
                if let rightPage { ordered.append(rightPage) }
                if let leftPage { ordered.append(leftPage) }
            }
            return ordered
        }
    }

    func rebuildSingleSplitPage(
        _ page: ScannedBookPage,
        newSplitRatio: CGFloat,
        newGutterTrimRatio: CGFloat,
        enhancement: EnhancementFilter,
        removeFingers: Bool
    ) -> ScannedBookPage {
        guard let cgImage = page.sourceSpreadImage.cgImage else { return page }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let rawImageToFilter: UIImage
        if page.sideLabel == .full {
            rawImageToFilter = page.sourceSpreadImage
        } else {
            let splitX = width * newSplitRatio
            let trimPx = width * min(max(newGutterTrimRatio, 0.0), 0.06)

            let cropRect: CGRect
            if page.sideLabel == .left {
                let leftWidth = max(1.0, splitX - trimPx)
                cropRect = CGRect(x: 0, y: 0, width: leftWidth, height: height).integral
            } else {
                let rightStartX = min(width - 1.0, splitX + trimPx)
                let rightWidth = max(1.0, width - rightStartX)
                cropRect = CGRect(x: rightStartX, y: 0, width: rightWidth, height: height).integral
            }

            guard let croppedCG = cgImage.cropping(to: cropRect) else { return page }
            rawImageToFilter = UIImage(cgImage: croppedCG, scale: 1.0, orientation: .up)
        }

        var enhanced = applyEnhancement(
            rawImageToFilter,
            filter: enhancement,
            removeFingersAtEdges: removeFingers
        )
        let turns = (page.rotationDegrees / 90) % 4
        if turns > 0 {
            for _ in 0..<turns {
                enhanced = rotate90Degrees(enhanced, clockwise: true)
            }
        }

        var updated = page
        updated.processedImage = enhanced
        updated.splitRatio = newSplitRatio
        updated.gutterTrimRatio = newGutterTrimRatio
        updated.filter = enhancement
        updated.removeFingersAtEdges = removeFingers
        return updated
    }

    /// Nhận diện văn bản OCR Tiếng Việt & Tiếng Anh bằng Apple Vision (`Run Text Recognition`)
    func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = normalizeOrientation(image).cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["vi-VN", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    /// Xuất PDF chất lượng cao
    func generatePDF(from pages: [ScannedBookPage], fileName: String) -> URL? {
        guard !pages.isEmpty else { return nil }
        let safeName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "phong_ve_chinh_dang"
            : fileName.trimmingCharacters(in: .whitespacesAndNewlines)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).pdf")

        let defaultBounds = CGRect(x: 0, y: 0, width: 1240, height: 1754)
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds)

        do {
            try renderer.writePDF(to: outputURL) { context in
                for page in pages {
                    autoreleasepool {
                        let img = page.processedImage
                        let imgSize = img.size
                        guard imgSize.width > 0, imgSize.height > 0 else { return }
                        let pageBounds = CGRect(origin: .zero, size: imgSize)
                        context.beginPage(withBounds: pageBounds, pageInfo: [:])
                        img.draw(in: pageBounds)
                    }
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }
}

// MARK: - vFlat Real-Time Camera & Strict Book-Detection Auto-Capture Controller

final class VFlatCameraController: NSObject, ObservableObject {
    @Published var detectedBookRect: NormalizedBookRect = .defaultSpread
    @Published var isBookDetected: Bool = false
    @Published var autoCaptureEnabled: Bool = true {
        didSet {
            if !autoCaptureEnabled {
                autoStatus = .manualOnly
                autoFillProgress = 0.0
            } else {
                autoStatus = isBookDetected ? .stabilizing(progress: 0) : .noBookDetected
                autoFillProgress = 0.0
            }
        }
    }
    @Published var autoFillProgress: CGFloat = 0.0
    @Published var autoStatus: AutoCaptureStatus = .noBookDetected
    @Published var captureLightProfile: AutoCaptureLightProfile = .autoAdaptive
    @Published var diagnosticsEnabled: Bool = false
    @Published private(set) var diagnosticsSnapshot: AutoCaptureDiagnosticsSnapshot?
    @Published private(set) var diagnosticsEvents: [String] = []
    @Published private(set) var lowLightSuggestionText: String? = nil
    @Published private(set) var lastAutoCaptureConvergenceSeconds: Double? = nil
    @Published private(set) var autoCaptureSuccessCount: Int = 0
    @Published var isTorchOn: Bool = false
    @Published var holdDurationSeconds: Double = 0.6
    @Published var shutterFlashTrigger: Bool = false
    @Published var cameraPermissionDenied: Bool = false
    /// Tỷ lệ rộng/cao của khung hình video (dọc), dùng để quy đổi khung sách sang tọa độ Preview (resizeAspectFill)
    @Published var previewBufferAspect: CGFloat = 3.0 / 4.0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.personal.booksplit.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.personal.booksplit.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Ảnh chụp + 4 góc trang sách thấy trên Preview lúc bấm chụp (dùng để cắt & nắn phẳng sau)
    var onPhotoCaptured: ((UIImage, PageQuad?) -> Void)?

    private var previousLumaGrid: [UInt8] = []      // Lưới độ sáng trung bình theo ô (đo rung tay)
    private var previousDetailGrid: [UInt8] = []    // Lưới điểm chi tiết (so sánh nội dung trang mới/cũ)
    private var lastCapturedLumaGrid: [UInt8] = []
    private var previousFrameQuad: PageQuad?         // Chỉ dùng trên videoOutputQueue
    private var lastSeenPageQuad: PageQuad?          // Chỉ dùng trên main thread
    private var pendingCaptureQuadHint: PageQuad?    // Chỉ dùng trên main thread
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var firstBookDetectedTimestamp: CFTimeInterval?
    private var stableElapsedSeconds: Double = 0
    private var consecutiveBookDetectedFrames: Int = 0
    private var consecutiveNoBookFrames: Int = 0
    private var sustainedLowLightFrames: Int = 0
    private var pageTurnMotionFrames: Int = 0
    private var isCapturingPhoto: Bool = false
    private var isSessionConfigured: Bool = false
    private var lastDiagnosticsTag: String = ""
    private var lastDiagnosticsEmitTimestamp: CFTimeInterval = 0

    // Tạo sẵn 1 lần, chỉ dùng trên videoOutputQueue
    private let documentRequest = VNDetectDocumentSegmentationRequest()
    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        // Tỷ lệ cạnh ngắn/cạnh dài phải nằm trong [0, 1]
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.3
        request.minimumConfidence = 0.5
        request.quadratureTolerance = 40 // Trang sách mở thường bị cong, không vuông góc tuyệt đối
        request.maximumObservations = 4
        return request
    }()

    func startSession() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                self.cameraPermissionDenied = !granted
            }
            guard granted else { return }
            self.sessionQueue.async {
                if !self.isSessionConfigured {
                    self.configureSession()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            // Xoay khung hình phân tích về chiều dọc giống Preview để tọa độ khung sách khớp với màn hình
            if let conn = videoOutput.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()
        isSessionConfigured = true
    }

    func toggleTorch() {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                let nextState = !device.isTorchActive
                device.torchMode = nextState ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.isTorchOn = nextState
                }
            } catch {}
        }
    }

    func triggerManualCapture(source: CaptureTriggerSource = .manual) {
        guard !isCapturingPhoto else { return }
        isCapturingPhoto = true
        lastCapturedLumaGrid = previousDetailGrid
        pendingCaptureQuadHint = isBookDetected ? lastSeenPageQuad : nil
        if source == .auto {
            autoCaptureSuccessCount += 1
            if let t0 = firstBookDetectedTimestamp {
                lastAutoCaptureConvergenceSeconds = max(0, CACurrentMediaTime() - t0)
            }
            appendDiagnosticsEvent("AUTO_CAPTURE_PASS source=\(source.rawValue)")
        } else {
            appendDiagnosticsEvent("CAPTURE_MANUAL source=\(source.rawValue)")
        }
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            self.autoStatus = .capturing
            self.autoFillProgress = 0.0
            withAnimation(.easeOut(duration: 0.15)) {
                self.shutterFlashTrigger = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.shutterFlashTrigger = false
            }
        }

        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true
            // Cân bằng tốc độ/chất lượng: chụp nhanh hơn để giảm nhòe khi cầm tay
            settings.photoQualityPrioritization = .balanced
            if let conn = self.photoOutput.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func armImmediateCapture() {
        videoOutputQueue.async {
            self.stableElapsedSeconds = 0
            self.pageTurnMotionFrames = 0
            self.lastCapturedLumaGrid = []
            DispatchQueue.main.async {
                if self.autoCaptureEnabled {
                    self.autoStatus = self.isBookDetected ? .stabilizing(progress: 0) : .noBookDetected
                    self.autoFillProgress = 0
                }
            }
        }
    }

    private func appendDiagnosticsEvent(_ message: String) {
        guard diagnosticsEnabled else { return }
        let ts = String(format: "%.2f", CACurrentMediaTime())
        diagnosticsEvents.append("[\(ts)] \(message)")
        if diagnosticsEvents.count > 80 {
            diagnosticsEvents.removeFirst(diagnosticsEvents.count - 80)
        }
    }
}

extension VFlatCameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTimestamp >= 0.095 else { return }
        let dt = lastFrameTimestamp == 0 ? 0.1 : min(0.35, now - lastFrameTimestamp)
        lastFrameTimestamp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Khung hình video đã được xoay dọc (portrait) giống hệt Preview -> tọa độ Vision khớp với màn hình
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bufferAspect = CGFloat(bufferWidth) / CGFloat(max(1, bufferHeight))

        // 1. Đo chuyển động khung hình (rung tay / lật trang) và độ khác biệt so với trang vừa chụp
        let (motionScore, diffFromLastCapture) = analyzeFrameMotion(pixelBuffer: pixelBuffer)

        // 2. Tìm biên trang sách bằng Apple Vision:
        //    - VNDetectDocumentSegmentationRequest (mô hình AI chuyên nhận diện giấy/tài liệu, hoạt động tốt với sách cong)
        //    - VNDetectRectanglesRequest làm phương án dự phòng
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([documentRequest, rectangleRequest])
        } catch {
            // Bỏ qua frame lỗi, vẫn tiếp tục kiểm tra nội dung giấy/chữ ở vùng trung tâm
        }

        let quad = bestPageQuad(bufferAspect: bufferAspect)

        // Độ dịch chuyển của khung sách giữa 2 frame: rung tay nhẹ chỉ làm khung xê dịch rất ít
        var quadShift: CGFloat = 0
        if let current = quad?.corners, let previous = previousFrameQuad {
            quadShift = current.maxCornerDistance(to: previous)
        }
        previousFrameQuad = quad?.corners
        let quadForHint = quad?.corners

        // 3. Xác minh bên trong khung thật sự là trang giấy có chữ in (tránh tự chụp khi chĩa vào bàn/sàn nhà)
        //    Nếu camera để sát sách (không thấy mép sách), kiểm tra vùng trung tâm khung hình.
        let centerRegion = CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76)
        let region = quad?.rect ?? centerRegion
        let metrics = evaluatePageContent(pixelBuffer: pixelBuffer, region: region)

        let rawBookDetected: Bool
        let candidateRect: NormalizedBookRect
        if let quad {
            let adaptive = adaptiveCaptureThresholds(for: metrics, holdDuration: holdDurationSeconds)
            let hasPaper = metrics.paperLevel >= adaptive.minPaperLevel && metrics.paperRatio >= adaptive.minPaperRatioWithQuad
            let trustedDocument = quad.isDocument && quad.confidence >= 0.8
            rawBookDetected = hasPaper && (metrics.textTransitions >= adaptive.minTextTransitionsWithQuad || trustedDocument)
            candidateRect = NormalizedBookRect(
                x: quad.rect.minX, y: quad.rect.minY, width: quad.rect.width, height: quad.rect.height
            )
        } else {
            let adaptive = adaptiveCaptureThresholds(for: metrics, holdDuration: holdDurationSeconds)
            let hasPaper = metrics.paperLevel >= adaptive.minPaperLevel && metrics.paperRatio >= adaptive.minPaperRatioWithQuad
            // Không thấy mép sách: chỉ chấp nhận khi nền giấy sáng và mật độ chữ rất rõ ràng
            rawBookDetected = hasPaper &&
            metrics.paperRatio >= adaptive.minPaperRatioNoQuad &&
            metrics.textTransitions >= adaptive.minTextTransitionsNoQuad
            candidateRect = NormalizedBookRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92)
        }

        // Bộ lọc chống nhiễu: cần 3 frame liên tiếp để xác nhận có sách, mất 3 frame liên tiếp mới coi là mất sách
        if rawBookDetected {
            consecutiveBookDetectedFrames += 1
            consecutiveNoBookFrames = 0
        } else {
            consecutiveNoBookFrames += 1
            if consecutiveNoBookFrames >= 3 {
                consecutiveBookDetectedFrames = 0
            }
        }

        let confirmedBookPresent = consecutiveBookDetectedFrames >= 3

        DispatchQueue.main.async {
            if abs(self.previewBufferAspect - bufferAspect) > 0.001 {
                self.previewBufferAspect = bufferAspect
            }
            if rawBookDetected {
                self.lastSeenPageQuad = quadForHint
            }
            if confirmedBookPresent {
                if !self.isBookDetected {
                    self.detectedBookRect = candidateRect
                } else if rawBookDetected {
                    self.detectedBookRect = self.detectedBookRect.interpolated(with: candidateRect, alpha: 0.35)
                }
            }
            self.isBookDetected = confirmedBookPresent

            if confirmedBookPresent {
                if self.firstBookDetectedTimestamp == nil {
                    self.firstBookDetectedTimestamp = now
                }
            } else {
                self.firstBookDetectedTimestamp = nil
            }

            if metrics.paperLevel < 88 {
                self.sustainedLowLightFrames += 1
            } else {
                self.sustainedLowLightFrames = 0
            }

            if self.captureLightProfile == .autoAdaptive, self.sustainedLowLightFrames >= 18 {
                self.lowLightSuggestionText = "Thiếu sáng → nên bật Low light để dễ tự chụp hơn"
            } else if self.captureLightProfile == .lowLight {
                self.lowLightSuggestionText = nil
            } else if self.sustainedLowLightFrames < 8 {
                self.lowLightSuggestionText = nil
            }

            guard self.autoCaptureEnabled, !self.isCapturingPhoto else { return }
            let adaptive = self.adaptiveCaptureThresholds(for: metrics, holdDuration: self.holdDurationSeconds)
            var diagnosticsTag = "PASS_STABILIZING"

            // QUAN TRỌNG: Nếu KHÔNG nhận diện được trang sách -> Tuyệt đối không tự chụp, đưa thanh đếm về 0% ngay lập tức!
            if !confirmedBookPresent {
                diagnosticsTag = "FAIL_NO_BOOK"
                self.stableElapsedSeconds = 0
                self.autoFillProgress = 0.0
                if self.autoStatus != .waitingForPageTurn {
                    self.autoStatus = .noBookDetected
                } else if motionScore > adaptive.noBookMotionThreshold {
                    self.pageTurnMotionFrames += 1
                }
                if self.diagnosticsEnabled {
                    let shouldEmit = self.lastDiagnosticsTag != diagnosticsTag || now - self.lastDiagnosticsEmitTimestamp >= 0.7
                    if shouldEmit {
                        self.lastDiagnosticsTag = diagnosticsTag
                        self.lastDiagnosticsEmitTimestamp = now
                        self.diagnosticsSnapshot = AutoCaptureDiagnosticsSnapshot(
                            timestamp: Date(),
                            paperLevel: metrics.paperLevel,
                            paperRatio: metrics.paperRatio,
                            textTransitions: metrics.textTransitions,
                            motionScore: motionScore,
                            quadShift: quadShift,
                            decision: diagnosticsTag
                        )
                        self.appendDiagnosticsEvent("\(diagnosticsTag) profile=\(self.captureLightProfile.rawValue)")
                    }
                }
                return
            }

            // Nếu vừa chụp xong 1 trang đôi, bắt buộc chờ người dùng lật sang trang mới
            // (phải có chuyển động lật trang VÀ nội dung trang mới khác trang vừa chụp)
            if self.autoStatus == .waitingForPageTurn {
                if motionScore > adaptive.pageTurnMotionThreshold {
                    self.pageTurnMotionFrames += 1
                }
                if self.pageTurnMotionFrames >= 2 &&
                    diffFromLastCapture > adaptive.pageTurnDiffThreshold &&
                    motionScore < adaptive.pageTurnStillThreshold {
                    diagnosticsTag = "PASS_PAGE_TURN_READY"
                    self.stableElapsedSeconds = 0
                    self.autoFillProgress = 0
                    self.autoStatus = .stabilizing(progress: 0)
                } else {
                    diagnosticsTag = "FAIL_WAIT_PAGE_TURN"
                }
                if self.diagnosticsEnabled {
                    let shouldEmit = self.lastDiagnosticsTag != diagnosticsTag || now - self.lastDiagnosticsEmitTimestamp >= 0.7
                    if shouldEmit {
                        self.lastDiagnosticsTag = diagnosticsTag
                        self.lastDiagnosticsEmitTimestamp = now
                        self.diagnosticsSnapshot = AutoCaptureDiagnosticsSnapshot(
                            timestamp: Date(),
                            paperLevel: metrics.paperLevel,
                            paperRatio: metrics.paperRatio,
                            textTransitions: metrics.textTransitions,
                            motionScore: motionScore,
                            quadShift: quadShift,
                            decision: diagnosticsTag
                        )
                        self.appendDiagnosticsEvent("\(diagnosticsTag) profile=\(self.captureLightProfile.rawValue)")
                    }
                }
                return
            }

            // Chụp kiểu vFlat: chỉ cần thấy trang sách và cầm máy TƯƠNG ĐỐI yên (cho phép rung tay nhẹ),
            // ảnh sẽ được chụp rộng kèm phần rìa rồi cắt & nắn phẳng ở bước xử lý sau.
            let isRoughlyStill = motionScore < adaptive.stillMotionThreshold &&
            quadShift < adaptive.stillQuadShiftThreshold
            if isRoughlyStill {
                self.stableElapsedSeconds += dt
                let progress = min(1.0, max(0.0, CGFloat(self.stableElapsedSeconds / self.holdDurationSeconds)))
                self.autoFillProgress = progress
                self.autoStatus = .stabilizing(progress: progress)

                if progress >= 1.0 {
                    diagnosticsTag = "PASS_TRIGGER_AUTO_CAPTURE"
                    self.stableElapsedSeconds = 0
                    self.pageTurnMotionFrames = 0
                    self.triggerManualCapture(source: .auto)
                }
            } else if motionScore > adaptive.hardResetMotionThreshold {
                diagnosticsTag = "FAIL_HARD_MOTION_RESET"
                // Di chuyển mạnh / đang lật trang -> đếm lại từ đầu
                self.stableElapsedSeconds = 0
                self.autoFillProgress = 0
                self.autoStatus = .stabilizing(progress: 0)
            } else {
                diagnosticsTag = "FAIL_SOFT_MOTION_DECAY"
                // Rung tay vừa phải: chỉ giảm từ từ, không bắt người dùng giữ lại từ đầu
                self.stableElapsedSeconds = max(0.0, self.stableElapsedSeconds - dt)
                let progress = min(1.0, max(0.0, CGFloat(self.stableElapsedSeconds / self.holdDurationSeconds)))
                self.autoFillProgress = progress
                self.autoStatus = .stabilizing(progress: progress)
            }

            if self.diagnosticsEnabled {
                let shouldEmit = self.lastDiagnosticsTag != diagnosticsTag || now - self.lastDiagnosticsEmitTimestamp >= 0.7
                if shouldEmit {
                    self.lastDiagnosticsTag = diagnosticsTag
                    self.lastDiagnosticsEmitTimestamp = now
                    self.diagnosticsSnapshot = AutoCaptureDiagnosticsSnapshot(
                        timestamp: Date(),
                        paperLevel: metrics.paperLevel,
                        paperRatio: metrics.paperRatio,
                        textTransitions: metrics.textTransitions,
                        motionScore: motionScore,
                        quadShift: quadShift,
                        decision: diagnosticsTag
                    )
                    self.appendDiagnosticsEvent("\(diagnosticsTag) profile=\(self.captureLightProfile.rawValue)")
                }
            }
        }
    }

    /// Khung trang sách tìm được trong frame (tọa độ chuẩn hóa, gốc trên-trái, theo khung hình dọc)
    private struct DetectedPageQuad {
        let rect: CGRect
        let corners: PageQuad
        let confidence: Float
        let isDocument: Bool
    }

    /// Kết quả đo nền giấy & chữ in bên trong một vùng của khung hình
    private struct PageContentMetrics {
        let paperLevel: Double      // Độ sáng nền giấy (bách phân vị 70%)
        let paperRatio: Double      // Tỷ lệ điểm ảnh thuộc nền giấy
        let textTransitions: Int    // Số lần chuyển từ nền giấy sang nét chữ tối dọc các đường quét
    }

    /// Bộ ngưỡng tự chụp được tinh chỉnh theo điều kiện ánh sáng và tốc độ giữ (0.6 / 1.0 / 1.5s)
    private struct AdaptiveCaptureThresholds {
        let minPaperLevel: Double
        let minPaperRatioWithQuad: Double
        let minPaperRatioNoQuad: Double
        let minTextTransitionsWithQuad: Int
        let minTextTransitionsNoQuad: Int
        let noBookMotionThreshold: Double
        let pageTurnMotionThreshold: Double
        let pageTurnDiffThreshold: Double
        let pageTurnStillThreshold: Double
        let stillMotionThreshold: Double
        let stillQuadShiftThreshold: CGFloat
        let hardResetMotionThreshold: Double
    }

    private func adaptiveCaptureThresholds(
        for metrics: PageContentMetrics,
        holdDuration: Double
    ) -> AdaptiveCaptureThresholds {
        let lowLight: Bool
        switch captureLightProfile {
        case .autoAdaptive:
            lowLight = metrics.paperLevel < 92
        case .lowLight:
            lowLight = true
        case .normalLight:
            lowLight = false
        }
        let slowHoldMode = holdDuration >= 1.2

        var stillMotion = lowLight ? 0.036 : 0.03
        var stillQuadShift: CGFloat = lowLight ? 0.040 : 0.035
        var hardResetMotion = lowLight ? 0.10 : 0.08

        if slowHoldMode {
            stillMotion += 0.003
            stillQuadShift += 0.004
            hardResetMotion += 0.01
        }

        return AdaptiveCaptureThresholds(
            minPaperLevel: lowLight ? 72 : 80,
            minPaperRatioWithQuad: lowLight ? 0.34 : 0.40,
            minPaperRatioNoQuad: lowLight ? 0.48 : 0.55,
            minTextTransitionsWithQuad: lowLight ? 12 : 16,
            minTextTransitionsNoQuad: lowLight ? 24 : 30,
            noBookMotionThreshold: lowLight ? 0.042 : 0.038,
            pageTurnMotionThreshold: lowLight ? 0.038 : 0.034,
            pageTurnDiffThreshold: lowLight ? 0.020 : 0.025,
            pageTurnStillThreshold: lowLight ? 0.035 : 0.03,
            stillMotionThreshold: stillMotion,
            stillQuadShiftThreshold: stillQuadShift,
            hardResetMotionThreshold: hardResetMotion
        )
    }

    /// Chọn khung trang sách tốt nhất: ưu tiên kết quả AI nhận diện tài liệu, sau đó đến hình chữ nhật lớn nhất
    private func bestPageQuad(bufferAspect: CGFloat) -> DetectedPageQuad? {
        func toTopLeftRect(_ bbox: CGRect) -> CGRect {
            CGRect(x: bbox.minX, y: 1.0 - bbox.maxY, width: bbox.width, height: bbox.height)
        }

        if let doc = documentRequest.results?.first,
           doc.confidence >= 0.5,
           doc.boundingBox.width * doc.boundingBox.height >= 0.15 {
            return DetectedPageQuad(
                rect: toTopLeftRect(doc.boundingBox),
                corners: PageQuad(doc, sourceAspect: bufferAspect),
                confidence: doc.confidence,
                isDocument: true
            )
        }

        let rects = (rectangleRequest.results ?? []).filter {
            $0.confidence >= 0.5 && $0.boundingBox.width * $0.boundingBox.height >= 0.15
        }
        if let largest = rects.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) {
            return DetectedPageQuad(
                rect: toTopLeftRect(largest.boundingBox),
                corners: PageQuad(largest, sourceAspect: bufferAspect),
                confidence: largest.confidence,
                isDocument: false
            )
        }
        return nil
    }

    /// Kiểm tra vùng `region` (chuẩn hóa, gốc trên-trái) có phải nền giấy sáng kèm các dòng chữ in hay không.
    /// Ngưỡng được tính tương đối theo độ sáng nền giấy nên hoạt động cả khi ánh sáng yếu.
    /// Quét cả chiều ngang lẫn chiều dọc vì khi chụp 2 trang (cầm ngang) dòng chữ nằm dọc trong khung hình.
    private func evaluatePageContent(pixelBuffer: CVPixelBuffer, region: CGRect) -> PageContentMetrics {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return PageContentMetrics(paperLevel: 0, paperRatio: 0, textTransitions: 0)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)

        // Thu nhỏ vùng kiểm tra 8% mỗi cạnh để bỏ qua mép sách, ngón tay và nền bàn
        let inset = region.insetBy(dx: region.width * 0.08, dy: region.height * 0.08)
        let x0 = max(0, min(width - 2, Int(inset.minX * CGFloat(width))))
        let x1 = max(x0 + 1, min(width - 1, Int(inset.maxX * CGFloat(width))))
        let y0 = max(0, min(height - 2, Int(inset.minY * CGFloat(height))))
        let y1 = max(y0 + 1, min(height - 1, Int(inset.maxY * CGFloat(height))))

        // Lấy mẫu lưới 24x24 để ước lượng độ sáng nền giấy
        let samplesPerAxis = 24
        var samples = [UInt8]()
        samples.reserveCapacity(samplesPerAxis * samplesPerAxis)
        for sy in 0..<samplesPerAxis {
            let py = y0 + ((y1 - y0) * sy) / (samplesPerAxis - 1)
            let rowPtr = ptr + py * bytesPerRow
            for sx in 0..<samplesPerAxis {
                let px = x0 + ((x1 - x0) * sx) / (samplesPerAxis - 1)
                samples.append(rowPtr[px])
            }
        }
        samples.sort()
        let paperLevel = Double(samples[(samples.count * 70) / 100])
        let paperCutoff = UInt8(max(0, min(255, paperLevel * 0.75)))
        let paperCount = samples.reduce(0) { $0 + ($1 >= paperCutoff ? 1 : 0) }
        let paperRatio = Double(paperCount) / Double(samples.count)

        // Đếm số lần đi từ nền giấy xuống nét chữ tối trên 6 đường quét mỗi chiều
        let dropThreshold = max(14, Int(paperLevel * 0.18))
        let paperFloor = Int(paperLevel * 0.70)

        func countTransitions(along values: (Int) -> Int, length: Int) -> Int {
            let step = max(1, length / 480)
            var count = 0
            var prev = values(0)
            var i = step
            while i < length {
                let cur = values(i)
                if prev >= paperFloor && prev - cur >= dropThreshold {
                    count += 1
                }
                prev = cur
                i += step
            }
            return count
        }

        var verticalScanCount = 0
        var horizontalScanCount = 0
        for k in 1...6 {
            let colX = x0 + ((x1 - x0) * k) / 7
            verticalScanCount += countTransitions(along: { Int(ptr[(y0 + $0) * bytesPerRow + colX]) }, length: y1 - y0)

            let rowY = y0 + ((y1 - y0) * k) / 7
            let rowPtr = ptr + rowY * bytesPerRow
            horizontalScanCount += countTransitions(along: { Int(rowPtr[x0 + $0]) }, length: x1 - x0)
        }

        return PageContentMetrics(
            paperLevel: paperLevel,
            paperRatio: paperRatio,
            textTransitions: max(verticalScanCount, horizontalScanCount)
        )
    }

    /// Phân tích kênh độ chói (Y-plane) để:
    /// 1. Tính độ rung/chuyển động giữa 2 frame liên tiếp (`motionScore`)
    /// 2. Tính độ khác biệt so với tấm ảnh vừa chụp (`diffFromLastCapture`)
    private func analyzeFrameMotion(pixelBuffer: CVPixelBuffer) -> (Double, Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return (1.0, 0.0)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)

        let gridW = 26
        let gridH = 36
        // currentGrid: trung bình 4x4 điểm trong mỗi ô -> không nhạy với nét chữ nhỏ khi tay rung nhẹ
        // detailGrid: 1 điểm giữa ô -> nhạy với nội dung, dùng để phân biệt trang mới với trang vừa chụp
        var currentGrid = [UInt8](repeating: 0, count: gridW * gridH)
        var detailGrid = [UInt8](repeating: 0, count: gridW * gridH)
        let cellW = max(1, width / gridW)
        let cellH = max(1, height / gridH)

        for gy in 0..<gridH {
            for gx in 0..<gridW {
                var sum = 0
                for sy in 0..<4 {
                    let py = min(height - 1, gy * cellH + (cellH * (2 * sy + 1)) / 8)
                    let rowPtr = ptr + py * bytesPerRow
                    for sx in 0..<4 {
                        let px = min(width - 1, gx * cellW + (cellW * (2 * sx + 1)) / 8)
                        sum += Int(rowPtr[px])
                    }
                }
                currentGrid[gy * gridW + gx] = UInt8(sum / 16)

                let cy = min(height - 1, gy * cellH + cellH / 2)
                let cx = min(width - 1, gx * cellW + cellW / 2)
                detailGrid[gy * gridW + gx] = ptr[cy * bytesPerRow + cx]
            }
        }

        var motionScore = 1.0
        if previousLumaGrid.count == currentGrid.count {
            var diffSum = 0
            for i in 0..<currentGrid.count {
                diffSum += abs(Int(currentGrid[i]) - Int(previousLumaGrid[i]))
            }
            motionScore = Double(diffSum) / Double(currentGrid.count * 255)
        }
        previousLumaGrid = currentGrid
        previousDetailGrid = detailGrid

        var diffFromLastCapture = 1.0
        if lastCapturedLumaGrid.count == detailGrid.count {
            var capDiff = 0
            for i in 0..<detailGrid.count {
                capDiff += abs(Int(detailGrid[i]) - Int(lastCapturedLumaGrid[i]))
            }
            diffFromLastCapture = Double(capDiff) / Double(detailGrid.count * 255)
        }

        return (motionScore, diffFromLastCapture)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer {
            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                if self.autoCaptureEnabled {
                    self.autoStatus = .waitingForPageTurn
                    self.autoFillProgress = 0.0
                }
            }
        }
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        DispatchQueue.main.async {
            let hint = self.pendingCaptureQuadHint
            self.pendingCaptureQuadHint = nil
            self.onPhotoCaptured?(image, hint)
        }
    }
}

// MARK: - Live Camera Preview Layer (Khóa cố định Portrait để không bao giờ bị xoay nhầm bởi cảm biến iPhone)

struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.lockPortraitOrientation()
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            lockPortraitOrientation()
        }

        func lockPortraitOrientation() {
            guard let connection = videoPreviewLayer.connection,
                  connection.isVideoOrientationSupported else { return }
            if connection.videoOrientation != .portrait {
                connection.videoOrientation = .portrait
            }
        }
    }
}

// MARK: - Share Sheet Wrapper

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Root Container

struct VFlatMainContainerView: View {
    @StateObject private var cameraController = VFlatCameraController()

    @State private var pages: [ScannedBookPage] = []
    @State private var twoPageMode: Bool = true
    @State private var landscapeFlipped180: Bool = false
    @State private var readingDirection: ReadingDirection = .leftToRight
    @State private var enhancementFilter: EnhancementFilter = .cleanBook
    @State private var removeFingersAtEdges: Bool = true
    @State private var gutterTrimPercent: Double = 1.5
    @State private var folderName: String = "phong ve chinh dang"

    @State private var isShowingLibrary: Bool = false
    @State private var activePageViewerIndex: Int? = nil
    @State private var rescanMode: RescanMode = .normalAppend

    @State private var isProcessingShot: Bool = false
    @State private var statusToastText: String? = nil
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var exportedFileURL: URL? = nil
    @State private var isShowingShareSheet: Bool = false

    private let vFlatTeal = Color(red: 0.16, green: 0.84, blue: 0.72)

    var body: some View {
        ZStack {
            if isShowingLibrary {
                VFlatLibraryGridView(
                    pages: $pages,
                    folderName: $folderName,
                    readingDirection: $readingDirection,
                    enhancementFilter: $enhancementFilter,
                    removeFingersAtEdges: $removeFingersAtEdges,
                    selectedPhotoItems: $selectedPhotoItems,
                    onOpenCamera: { mode in
                        rescanMode = mode
                        cameraController.armImmediateCapture()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingLibrary = false
                        }
                    },
                    onSelectPageAtIndex: { idx in
                        activePageViewerIndex = idx
                    },
                    onExportPDF: {
                        exportPDF()
                    },
                    onRunBatchAICleanup: {
                        runBatchAICleanup()
                    }
                )
            } else {
                vFlatOrientationLockedCameraScreen
            }
        }
        .fullScreenCover(item: Binding(
            get: {
                if let idx = activePageViewerIndex, pages.indices.contains(idx) {
                    return PageViewerSelection(index: idx)
                }
                return nil
            },
            set: { newVal in
                activePageViewerIndex = newVal?.index
            }
        )) { selection in
            VFlatPagePagerView(
                pages: $pages,
                currentIndex: selection.index,
                folderName: folderName,
                onTriggerRescan: { mode in
                    activePageViewerIndex = nil
                    rescanMode = mode
                    cameraController.armImmediateCapture()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingLibrary = false
                    }
                },
                onExportPDF: {
                    exportPDF()
                }
            )
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let url = exportedFileURL {
                ActivityShareSheet(items: [url])
            }
        }
        .onAppear {
            cameraController.onPhotoCaptured = { capturedImage, pageQuadHint in
                handleCapturedPhoto(capturedImage, pageQuadHint: pageQuadHint)
            }
            cameraController.startSession()
        }
        .onChange(of: isShowingLibrary) { inLibrary in
            if inLibrary {
                cameraController.stopSession()
            } else {
                cameraController.startSession()
            }
        }
        .onChange(of: selectedPhotoItems) { newItems in
            guard !newItems.isEmpty else { return }
            importPhotosFromLibrary(newItems)
        }
    }

    // MARK: - 1. Màn hình Camera Khóa Cố Định Chiều Ngang Khi Quét 2 Trang (Không bị ảnh hưởng bởi Tự Xoay của iPhone)

    private var vFlatOrientationLockedCameraScreen: some View {
        GeometryReader { fullGeo in
            let W = fullGeo.size.width
            let H = fullGeo.size.height

            ZStack {
                // Lớp 1: Camera Preview gốc cố định trên toàn màn hình
                CameraPreviewLayerView(session: cameraController.session)
                    .ignoresSafeArea()

                // Lớp 2: Giao diện điều khiển & Khung [1 | 2]
                // Khi ở chế độ 2 Trang (`twoPageMode == true`), giao diện tự động xoay ngang 90° cố định
                // (Tai thỏ ở bên trái, Bảng điều khiển ở bên phải, vạch đứt nét cắt dọc đúng giữa gáy sách!)
                if twoPageMode {
                    let landscapeW = H
                    let landscapeH = W
                    let rotationAngle: Angle = landscapeFlipped180 ? .degrees(-90) : .degrees(90)

                    HStack(spacing: 0) {
                        horizontalBookViewfinderOverlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        vFlatLandscapeRightControlPanel
                            .frame(width: 188)
                            .background(Color.white)
                    }
                    .frame(width: landscapeW, height: landscapeH)
                    .rotationEffect(rotationAngle)
                    .position(x: W / 2.0, y: H / 2.0)
                } else {
                    // Khi ở chế độ 1 Trang đơn (`twoPageMode == false`), hiển thị dọc theo trang đơn
                    VStack(spacing: 0) {
                        singlePagePortraitViewfinderOverlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        vFlatPortraitBottomControlPanel
                            .frame(height: 188)
                            .background(Color.white)
                    }
                    .frame(width: W, height: H)
                }

                // Hiệu ứng chớp màn trập khi chụp
                if cameraController.shutterFlashTrigger {
                    Color.white.opacity(0.65)
                        .ignoresSafeArea()
                }

                if cameraController.diagnosticsEnabled {
                    VStack {
                        HStack {
                            diagnosticsOverlayCard
                            Spacer()
                        }
                        .padding(.leading, 10)
                        .padding(.top, 42)
                        Spacer()
                    }
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    /// Giao diện kính ngắm nằm ngang chuẩn cho 2 trang sách:
    /// - Vạch đứt nét chạy DỌC từ cạnh trên xuống cạnh dưới màn hình ngang (cắt đúng gáy sách)
    /// - Số 1 nằm bên Trang Trái, Số 2 nằm bên Trang Phải, đứng thẳng đúng chiều người đọc
    /// - Chỉ sáng viền xanh ngọc và tự đếm chụp khi thực sự nhận diện được trang sách (`isBookDetected == true`)
    private var horizontalBookViewfinderOverlay: some View {
        GeometryReader { viewGeo in
            let bRect = viewfinderBookRect(overlaySize: viewGeo.size, landscape: true)
            let boxWidth = viewGeo.size.width * (cameraController.isBookDetected ? bRect.width : 0.84)
            let boxHeight = viewGeo.size.height * (cameraController.isBookDetected ? bRect.height : 0.78)
            let boxCenterX = viewGeo.size.width * (cameraController.isBookDetected ? (bRect.x + bRect.width / 2.0) : 0.50)
            let boxCenterY = viewGeo.size.height * (cameraController.isBookDetected ? (bRect.y + bRect.height / 2.0) : 0.50)

            ZStack {
                // Khung 2 trang sách [1 | 2]
                ZStack {
                    // Thanh màu xanh ngọc dâng từ đáy sách lên đỉnh sách khi nhận diện được sách & giữ yên
                    if cameraController.isBookDetected && cameraController.autoFillProgress > 0.01 {
                        GeometryReader { boxGeo in
                            let fillH = boxGeo.size.height * cameraController.autoFillProgress
                            Rectangle()
                                .fill(vFlatTeal.opacity(0.42))
                                .frame(width: boxGeo.size.width, height: fillH)
                                .position(
                                    x: boxGeo.size.width / 2.0,
                                    y: boxGeo.size.height - fillH / 2.0
                                )
                        }
                    }

                    // Viền khung: Xanh ngọc nét liền khi ĐÃ nhận diện được trang sách; Trắng mờ nét đứt khi CHƯA thấy sách
                    if cameraController.isBookDetected {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(vFlatTeal, lineWidth: 3.4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                Color.white.opacity(0.55),
                                style: StrokeStyle(lineWidth: 2.2, dash: [8, 6])
                            )
                    }

                    // Đường đứt nét trắng chạy DỌC theo gáy sách (chia đôi Trang Trái 1 và Trang Phải 2)
                    Canvas { ctx, size in
                        var path = Path()
                        path.move(to: CGPoint(x: size.width / 2.0, y: -10))
                        path.addLine(to: CGPoint(x: size.width / 2.0, y: size.height + 10))
                        ctx.stroke(
                            path,
                            with: .color(cameraController.isBookDetected ? .white : .white.opacity(0.55)),
                            style: StrokeStyle(lineWidth: 3.0, lineCap: .round, dash: [10, 8])
                        )
                    }

                    // Số 1 (Trang Trái) và Số 2 (Trang Phải) đứng thẳng chuẩn chiều ngang của sách
                    HStack(spacing: 0) {
                        Text(readingDirection == .leftToRight ? "1" : "2")
                            .font(.system(size: 84, weight: .medium, design: .rounded))
                            .foregroundStyle(
                                cameraController.isBookDetected
                                    ? Color.black.opacity(0.35)
                                    : Color.white.opacity(0.28)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Text(readingDirection == .leftToRight ? "2" : "1")
                            .font(.system(size: 84, weight: .medium, design: .rounded))
                            .foregroundStyle(
                                cameraController.isBookDetected
                                    ? Color.black.opacity(0.35)
                                    : Color.white.opacity(0.28)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: boxWidth, height: boxHeight)
                .position(x: boxCenterX, y: boxCenterY)
                .animation(.easeOut(duration: 0.15), value: cameraController.isBookDetected)

                // Thanh trạng thái nằm ngang ở mép trên của khung ngắm
                VStack {
                    HStack(spacing: 10) {
                        if rescanMode != .normalAppend {
                            Button {
                                rescanMode = .normalAppend
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Đang chụp lại trang lỗi (Bấm để hủy)")
                                }
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.92))
                                .clipShape(Capsule())
                            }
                        } else {
                            statusBadgeOnViewfinder
                        }

                        Spacer()

                        if let toast = statusToastText {
                            Text(toast)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.78))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                    Spacer()
                }
            }
        }
    }

    /// Quy đổi khung sách từ tọa độ khung hình camera (dọc, gốc trên-trái) sang tọa độ chuẩn hóa của lớp khung ngắm:
    /// 1. Bù phần ảnh bị cắt do Preview dùng `resizeAspectFill`
    /// 2. Xoay sang hệ tọa độ ngang khi ở chế độ 2 trang (+90°, hoặc -90° nếu đã lật 180°)
    /// 3. Bỏ phần màn hình bị Bảng điều khiển (188pt) che
    private func viewfinderBookRect(overlaySize: CGSize, landscape: Bool) -> NormalizedBookRect {
        let panelSize: CGFloat = 188
        let r = cameraController.detectedBookRect
        let screenW = landscape ? overlaySize.height : overlaySize.width
        let screenH = landscape ? overlaySize.width + panelSize : overlaySize.height + panelSize
        guard screenW > 0, screenH > 0 else { return r }

        let screenAspect = screenW / screenH
        let bufferAspect = max(0.1, cameraController.previewBufferAspect)
        var sx = r.x, sy = r.y, sw = r.width, sh = r.height
        if bufferAspect > screenAspect {
            let k = bufferAspect / screenAspect
            sx = (r.x - 0.5) * k + 0.5
            sw = r.width * k
        } else {
            let k = screenAspect / bufferAspect
            sy = (r.y - 0.5) * k + 0.5
            sh = r.height * k
        }

        let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
        let visibleFraction = max(0.1, (screenH - panelSize) / screenH)
        if landscape {
            let u = landscapeFlipped180 ? 1.0 - sy - sh : sy
            let v = landscapeFlipped180 ? sx : 1.0 - sx - sw
            x = u / visibleFraction
            w = sh / visibleFraction
            y = v
            h = sw
        } else {
            x = sx
            w = sw
            y = sy / visibleFraction
            h = sh / visibleFraction
        }

        // Giới hạn khung trong vùng nhìn thấy
        let minX = max(0.01, x), minY = max(0.01, y)
        let maxX = min(0.99, x + w), maxY = min(0.99, y + h)
        guard maxX - minX > 0.15, maxY - minY > 0.15 else { return .defaultSpread }
        return NormalizedBookRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private var singlePagePortraitViewfinderOverlay: some View {
        GeometryReader { viewGeo in
            let bRect = viewfinderBookRect(overlaySize: viewGeo.size, landscape: false)
            let detected = cameraController.isBookDetected
            let boxW = viewGeo.size.width * (detected ? bRect.width : 0.82)
            let boxH = viewGeo.size.height * (detected ? bRect.height : 0.76)
            let boxCenterX = viewGeo.size.width * (detected ? (bRect.x + bRect.width / 2.0) : 0.50)
            let boxCenterY = viewGeo.size.height * (detected ? (bRect.y + bRect.height / 2.0) : 0.50)

            ZStack {
                ZStack {
                    if cameraController.isBookDetected && cameraController.autoFillProgress > 0.01 {
                        GeometryReader { boxGeo in
                            let fillH = boxGeo.size.height * cameraController.autoFillProgress
                            Rectangle()
                                .fill(vFlatTeal.opacity(0.42))
                                .frame(width: boxGeo.size.width, height: fillH)
                                .position(
                                    x: boxGeo.size.width / 2.0,
                                    y: boxGeo.size.height - fillH / 2.0
                                )
                        }
                    }

                    if cameraController.isBookDetected {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(vFlatTeal, lineWidth: 3.4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                Color.white.opacity(0.55),
                                style: StrokeStyle(lineWidth: 2.2, dash: [8, 6])
                            )
                    }

                    Text("1")
                        .font(.system(size: 84, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            cameraController.isBookDetected
                                ? Color.black.opacity(0.35)
                                : Color.white.opacity(0.28)
                        )
                }
                .frame(width: boxW, height: boxH)
                .position(x: boxCenterX, y: boxCenterY)
                .animation(.easeOut(duration: 0.15), value: cameraController.isBookDetected)

                VStack {
                    statusBadgeOnViewfinder
                        .padding(.top, 50)
                    if let toast = statusToastText {
                        Text(toast)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.78))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
            }
        }
    }

    private var statusBadgeOnViewfinder: some View {
        let labelText: String
        let badgeColor: Color

        switch cameraController.autoStatus {
        case .manualOnly:
            labelText = cameraController.isBookDetected
                ? "Đã nhận diện trang sách (Bấm nút tròn để chụp)"
                : "Chế độ chụp tay (Đưa sách vào khung ngắm)"
            badgeColor = .black.opacity(0.62)
        case .noBookDetected:
            labelText = "Đưa trang sách vào khung ngắm (Chỉ tự chụp khi nhận diện được sách)"
            badgeColor = .black.opacity(0.68)
        case .stabilizing(let progress):
            if progress > 0.04 {
                labelText = "Đã nhận diện trang sách — Đang tự chụp... \(Int(progress * 100))%"
                badgeColor = Color(red: 0.08, green: 0.62, blue: 0.52).opacity(0.90)
            } else {
                labelText = "Đã nhận diện trang sách — Giữ phẳng để tự chụp..."
                badgeColor = Color(red: 0.08, green: 0.62, blue: 0.52).opacity(0.85)
            }
        case .capturing:
            labelText = "Đang chụp & tách 2 trang..."
            badgeColor = .blue.opacity(0.88)
        case .waitingForPageTurn:
            labelText = "Đã lưu! Hãy lật sang trang tiếp theo để tự chụp tiếp"
            badgeColor = Color.green.opacity(0.85)
        }

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(cameraController.isBookDetected ? vFlatTeal : Color.gray)
                    .frame(width: 8, height: 8)
                Text(labelText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let suggestion = cameraController.lowLightSuggestionText {
                Text(suggestion)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.yellow.opacity(0.96))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(badgeColor)
        .clipShape(Capsule())
    }

    private var diagnosticsOverlayCard: some View {
        let snapshot = cameraController.diagnosticsSnapshot
        let latencyText: String
        if let latency = cameraController.lastAutoCaptureConvergenceSeconds {
            latencyText = String(format: "%.2fs", latency)
        } else {
            latencyText = "--"
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text("DEBUG AutoCapture")
                .font(.caption2.bold())
            Text("profile=\(cameraController.captureLightProfile.rawValue)")
                .font(.caption2.monospaced())
            Text("decision=\(snapshot?.decision ?? "--")")
                .font(.caption2.monospaced())
            Text(
                String(
                    format: "paper=%.1f ratio=%.2f text=%d",
                    snapshot?.paperLevel ?? 0,
                    snapshot?.paperRatio ?? 0,
                    snapshot?.textTransitions ?? 0
                )
            )
            .font(.caption2.monospaced())
            Text(
                String(
                    format: "motion=%.3f shift=%.3f",
                    snapshot?.motionScore ?? 0,
                    snapshot?.quadShift ?? 0
                )
            )
            .font(.caption2.monospaced())
            Text("AUTO pass=\(cameraController.autoCaptureSuccessCount) latency=\(latencyText)")
                .font(.caption2.monospaced())
            if let lastEvent = cameraController.diagnosticsEvents.last {
                Text(lastEvent)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Bảng điều khiển trắng bên phải màn hình ngang (Giống hệt Ảnh 1 & Ảnh 2 của vFlat)
    private var vFlatLandscapeRightControlPanel: some View {
        HStack(spacing: 6) {
            // Cột trái: 5 nút tính năng nhanh của vFlat (More, AUTO, Timer, Flash, [1|2])
            VStack(spacing: 0) {
                moreOptionsCameraMenu
                Spacer()
                autoCaptureToggleButton
                Spacer()
                timerSpeedButton
                Spacer()
                torchToggleButton
                Spacer()
                twoPageToggleButton
            }
            .padding(.vertical, 18)
            .frame(width: 44)

            // Cột phải: Library ở trên, Nút chụp tròn ở giữa, Thumbnail + Tên thư mục ở dưới
            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingLibrary = true
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 22, weight: .medium))
                        Text("Library (\(pages.count))")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.78))
                }
                .padding(.top, 16)

                Spacer()

                Button {
                    cameraController.triggerManualCapture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(
                                cameraController.isBookDetected ? vFlatTeal : Color.gray.opacity(0.38),
                                lineWidth: 5
                            )
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 60, height: 60)
                        if isProcessingShot {
                            ProgressView()
                                .tint(vFlatTeal)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 8) {
                    latestThumbnailButton
                    folderPillButton
                }
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
    }

    private var vFlatPortraitBottomControlPanel: some View {
        VStack(spacing: 12) {
            HStack {
                moreOptionsCameraMenu
                Spacer()
                autoCaptureToggleButton
                Spacer()
                timerSpeedButton
                Spacer()
                torchToggleButton
                Spacer()
                twoPageToggleButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingLibrary = true
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 22, weight: .medium))
                        Text("Library (\(pages.count))")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.black.opacity(0.75))
                }
                .frame(width: 90)

                Spacer()

                Button {
                    cameraController.triggerManualCapture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(
                                cameraController.isBookDetected ? vFlatTeal : Color.gray.opacity(0.38),
                                lineWidth: 5
                            )
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 60, height: 60)
                        if isProcessingShot {
                            ProgressView()
                                .tint(vFlatTeal)
                        }
                    }
                }

                Spacer()

                latestThumbnailButton
                    .frame(width: 90)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var moreOptionsCameraMenu: some View {
        Menu {
            Section("Phiên bản: \(AppVersionHelper.displayString)") {
                Picker("Thứ tự trang đôi", selection: $readingDirection) {
                    ForEach(ReadingDirection.allCases) { dir in
                        Text(dir.rawValue).tag(dir)
                    }
                }
                Picker("Chế độ làm sạch AI", selection: $enhancementFilter) {
                    ForEach(EnhancementFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                Picker("Ngưỡng tự chụp", selection: $cameraController.captureLightProfile) {
                    ForEach(AutoCaptureLightProfile.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Hiện Debug Auto-Capture", isOn: $cameraController.diagnosticsEnabled)
                Toggle("Tự xóa ngón tay ở mép sách", isOn: $removeFingersAtEdges)
                Button {
                    landscapeFlipped180.toggle()
                } label: {
                    Label("Đảo chiều màn hình ngang 180°", systemImage: "rectangle.landscape.rotate")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 21))
                .foregroundStyle(Color.black.opacity(0.65))
        }
    }

    private var autoCaptureToggleButton: some View {
        Button {
            cameraController.autoCaptureEnabled.toggle()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 16, weight: .bold))
                Text("AUTO")
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(cameraController.autoCaptureEnabled ? Color.orange : Color.gray.opacity(0.55))
        }
    }

    private var timerSpeedButton: some View {
        Button {
            if cameraController.holdDurationSeconds < 0.8 {
                cameraController.holdDurationSeconds = 1.0
                showToast("Tốc độ giữ tự chụp: 1.0 giây")
            } else if cameraController.holdDurationSeconds < 1.2 {
                cameraController.holdDurationSeconds = 1.5
                showToast("Tốc độ giữ tự chụp: 1.5 giây")
            } else {
                cameraController.holdDurationSeconds = 0.6
                showToast("Tốc độ giữ tự chụp: 0.6 giây (nhanh)")
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "timer")
                    .font(.system(size: 18))
                Text(String(format: "%.1fs", cameraController.holdDurationSeconds))
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.gray.opacity(0.75))
        }
    }

    private var torchToggleButton: some View {
        Button {
            cameraController.toggleTorch()
        } label: {
            Image(systemName: cameraController.isTorchOn ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 19))
                .foregroundStyle(cameraController.isTorchOn ? Color.orange : Color.gray.opacity(0.65))
        }
    }

    private var twoPageToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                twoPageMode.toggle()
            }
            showToast(twoPageMode ? "Chế độ 2 Trang: Đã khóa màn hình ngang [1|2]" : "Chế độ 1 Trang đơn")
        } label: {
            HStack(spacing: 1) {
                Text("1")
                Rectangle()
                    .frame(width: 1, height: 10)
                if twoPageMode {
                    Text("2")
                }
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(twoPageMode ? Color.black.opacity(0.78) : Color.gray.opacity(0.45), lineWidth: 1.4)
            )
            .foregroundStyle(twoPageMode ? Color.black.opacity(0.78) : Color.gray.opacity(0.45))
        }
    }

    private var latestThumbnailButton: some View {
        Button {
            if !pages.isEmpty {
                activePageViewerIndex = pages.count - 1
            } else {
                withAnimation { isShowingLibrary = true }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                if let lastPage = pages.last {
                    Image(uiImage: lastPage.processedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 46, height: 58)
                        .overlay(
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        )
                }

                if !pages.isEmpty {
                    Text("\(pages.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(vFlatTeal)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
    }

    private var folderPillButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingLibrary = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(folderName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.black.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    // MARK: - Xử lý ảnh vừa chụp

    private func handleCapturedPhoto(_ rawImage: UIImage, pageQuadHint: PageQuad?) {
        isProcessingShot = true
        let currentMode = rescanMode
        let isTwoPage = twoPageMode
        let isFlipped180 = landscapeFlipped180
        let currentDir = readingDirection
        let currentFilter = enhancementFilter
        let currentTrim = CGFloat(gutterTrimPercent / 100.0)
        let currentRemoveFingers = removeFingersAtEdges

        Task.detached(priority: .userInitiated) {
            switch currentMode {
            case .normalAppend:
                let newSplitPages = BookSpineProcessor.shared.processAndSplitCapturedShot(
                    rawImage,
                    twoPageMode: isTwoPage,
                    readingDirection: currentDir,
                    enhancement: currentFilter,
                    gutterTrimRatio: currentTrim,
                    removeFingers: currentRemoveFingers,
                    landscapeFlipped180: isFlipped180,
                    pageQuadHint: pageQuadHint
                )
                await MainActor.run {
                    self.pages.append(contentsOf: newSplitPages)
                    self.isProcessingShot = false
                    self.showToast(isTwoPage ? "Đã tự tách +2 trang (Tổng: \(self.pages.count))" : "Đã thêm +1 trang (Tổng: \(self.pages.count))")
                }

            case .replaceSinglePage(let targetID):
                let flattened = BookSpineProcessor.shared.prepareSpread(
                    rawImage,
                    hint: pageQuadHint,
                    isTwoPageMode: isTwoPage,
                    landscapeFlipped180: isFlipped180
                )
                let enhanced = BookSpineProcessor.shared.applyEnhancement(
                    flattened,
                    filter: currentFilter,
                    removeFingersAtEdges: currentRemoveFingers
                )
                await MainActor.run {
                    if let idx = self.pages.firstIndex(where: { $0.id == targetID }) {
                        var updated = self.pages[idx]
                        updated.sourceSpreadImage = flattened
                        updated.processedImage = enhanced
                        updated.sideLabel = .full
                        updated.rotationDegrees = 0
                        updated.recognizedText = nil
                        self.pages[idx] = updated
                        self.activePageViewerIndex = idx
                    }
                    self.rescanMode = .normalAppend
                    self.isProcessingShot = false
                    self.showToast("Đã chụp lại và thay thế trang thành công!")
                }

            case .replaceSpreadPair(let targetID):
                let newSplitPages = BookSpineProcessor.shared.processAndSplitCapturedShot(
                    rawImage,
                    twoPageMode: true,
                    readingDirection: currentDir,
                    enhancement: currentFilter,
                    gutterTrimRatio: currentTrim,
                    removeFingers: currentRemoveFingers,
                    landscapeFlipped180: isFlipped180,
                    pageQuadHint: pageQuadHint
                )
                await MainActor.run {
                    if let idx = self.pages.firstIndex(where: { $0.id == targetID }) {
                        let oldGroup = self.pages[idx].spreadGroupID
                        let firstIdx = self.pages.firstIndex(where: { $0.spreadGroupID == oldGroup }) ?? idx
                        self.pages.removeAll { $0.spreadGroupID == oldGroup }
                        let insertPos = min(firstIdx, self.pages.count)
                        self.pages.insert(contentsOf: newSplitPages, at: insertPos)
                        self.activePageViewerIndex = insertPos
                    }
                    self.rescanMode = .normalAppend
                    self.isProcessingShot = false
                    self.showToast("Đã chụp lại & tách cặp 2 trang mới!")
                }
            }
        }
    }

    private func importPhotosFromLibrary(_ items: [PhotosPickerItem]) {
        isProcessingShot = true
        let isTwoPage = twoPageMode
        let currentDir = readingDirection
        let currentFilter = enhancementFilter
        let currentTrim = CGFloat(gutterTrimPercent / 100.0)
        let currentRemoveFingers = removeFingersAtEdges

        Task {
            var importedPages: [ScannedBookPage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    let splitResult = BookSpineProcessor.shared.processAndSplitCapturedShot(
                        img,
                        twoPageMode: isTwoPage,
                        readingDirection: currentDir,
                        enhancement: currentFilter,
                        gutterTrimRatio: currentTrim,
                        removeFingers: currentRemoveFingers
                    )
                    importedPages.append(contentsOf: splitResult)
                }
            }
            await MainActor.run {
                selectedPhotoItems.removeAll()
                pages.append(contentsOf: importedPages)
                isProcessingShot = false
                showToast("Đã nhập và tách thành \(importedPages.count) trang!")
            }
        }
    }

    private func runBatchAICleanup() {
        guard !pages.isEmpty else { return }
        isProcessingShot = true
        showToast("Đang chạy AI Cleanup làm sạch toàn bộ \(pages.count) trang...")
        let snapshot = pages

        Task.detached(priority: .userInitiated) {
            let cleaned = snapshot.map { page in
                BookSpineProcessor.shared.rebuildSingleSplitPage(
                    page,
                    newSplitRatio: page.splitRatio,
                    newGutterTrimRatio: page.gutterTrimRatio,
                    enhancement: .cleanBook,
                    removeFingers: true
                )
            }
            await MainActor.run {
                self.pages = cleaned
                self.isProcessingShot = false
                self.showToast("Đã hoàn tất AI Cleanup cho \(cleaned.count) trang!")
            }
        }
    }

    private func exportPDF() {
        guard !pages.isEmpty else {
            showToast("Chưa có trang sách nào để xuất PDF")
            return
        }
        isProcessingShot = true
        showToast("Đang tạo file PDF...")
        let snapshot = pages
        let name = folderName

        Task.detached(priority: .userInitiated) {
            let url = BookSpineProcessor.shared.generatePDF(from: snapshot, fileName: name)
            await MainActor.run {
                self.isProcessingShot = false
                if let url {
                    self.exportedFileURL = url
                    self.isShowingShareSheet = true
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation {
            statusToastText = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if statusToastText == text {
                withAnimation {
                    statusToastText = nil
                }
            }
        }
    }
}

struct PageViewerSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 2. Màn Hình Thư Viện Lưới 2 Cột Chuẩn Giao Diện vFlat (Giống Ảnh 4)

struct VFlatLibraryGridView: View {
    @Binding var pages: [ScannedBookPage]
    @Binding var folderName: String
    @Binding var readingDirection: ReadingDirection
    @Binding var enhancementFilter: EnhancementFilter
    @Binding var removeFingersAtEdges: Bool
    @Binding var selectedPhotoItems: [PhotosPickerItem]

    var onOpenCamera: (RescanMode) -> Void
    var onSelectPageAtIndex: (Int) -> Void
    var onExportPDF: () -> Void
    var onRunBatchAICleanup: () -> Void

    @State private var isSelectionMode: Bool = false
    @State private var selectedPageIDs: Set<UUID> = []
    @State private var isEditingFolderName: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]
    private let vFlatTeal = Color(red: 0.09, green: 0.72, blue: 0.61)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    onOpenCamera(.normalAppend)
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                }

                if isEditingFolderName {
                    TextField("Tên thư mục sách", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { isEditingFolderName = false }
                } else {
                    Text(folderName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .onTapGesture { isEditingFolderName = true }
                }

                Spacer()

                if isSelectionMode {
                    Button("Xong") {
                        isSelectionMode = false
                        selectedPageIDs.removeAll()
                    }
                    .font(.subheadline.weight(.bold))
                } else {
                    Menu {
                        Text("BookSplitScanner \(AppVersionHelper.displayString)")
                        Divider()
                        Button {
                            isEditingFolderName = true
                        } label: {
                            Label("Đổi tên thư mục sách", systemImage: "pencil")
                        }
                        Picker("Thứ tự tách trang", selection: $readingDirection) {
                            ForEach(ReadingDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                        Toggle("Tự xóa ngón tay ở mép sách", isOn: $removeFingersAtEdges)
                        if !pages.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                pages.removeAll()
                            } label: {
                                Label("Xóa toàn bộ các trang", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white)

            ZStack(alignment: .bottomTrailing) {
                Color(white: 0.965).ignoresSafeArea()

                if pages.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 54))
                            .foregroundStyle(.gray.opacity(0.5))
                        Text("Chưa có trang sách nào trong thư mục")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Bấm nút Camera màu xanh ở góc dưới để bắt đầu quét tự động 2 trang.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                                vFlatGridItem(index: index, page: page)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 96)
                    }
                }

                Button {
                    onOpenCamera(.normalAppend)
                } label: {
                    ZStack {
                        Circle()
                            .fill(vFlatTeal)
                            .frame(width: 60, height: 60)
                            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)

                        Image(systemName: "camera.badge.plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.trailing, 22)
                .padding(.bottom, 20)
            }

            HStack(spacing: 0) {
                bottomBarItem(icon: "doc.richtext", title: "Create PDF", tint: .black) {
                    onExportPDF()
                }

                bottomBarItem(icon: "wand.and.stars.inverse", title: "AI Cleanup", tint: .black) {
                    onRunBatchAICleanup()
                }

                bottomBarItem(
                    icon: "trash",
                    title: isSelectionMode && !selectedPageIDs.isEmpty ? "Xóa (\(selectedPageIDs.count))" : "Delete",
                    tint: .red
                ) {
                    if isSelectionMode {
                        if !selectedPageIDs.isEmpty {
                            pages.removeAll { selectedPageIDs.contains($0.id) }
                            selectedPageIDs.removeAll()
                            isSelectionMode = false
                        } else {
                            isSelectionMode = false
                        }
                    } else {
                        isSelectionMode = true
                    }
                }

                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 50,
                    matching: .images
                ) {
                    VStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 19))
                        Text("Import")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }

                Menu {
                    Button {
                        onOpenCamera(.normalAppend)
                    } label: {
                        Label("Quét tiếp bằng Camera", systemImage: "camera")
                    }
                    Button {
                        isSelectionMode.toggle()
                        selectedPageIDs.removeAll()
                    } label: {
                        Label(isSelectionMode ? "Thoát chọn nhiều trang" : "Chọn nhiều trang để xóa", systemImage: "checkmark.circle")
                    }
                    if !pages.isEmpty {
                        Divider()
                        Button(role: .destructive) {
                            pages.removeAll()
                        } label: {
                            Label("Xóa tất cả trang", systemImage: "trash")
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 19))
                        Text("More")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .background(Color.white)
            .overlay(Divider(), alignment: .top)
        }
    }

    private func vFlatGridItem(index: Int, page: ScannedBookPage) -> some View {
        let isSelected = selectedPageIDs.contains(page.id)

        return VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: page.processedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 215)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                    .overlay(
                        Rectangle()
                            .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2.5)
                    )

                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .red : .gray)
                        .padding(8)
                }
            }
            .onTapGesture {
                if isSelectionMode {
                    if isSelected {
                        selectedPageIDs.remove(page.id)
                    } else {
                        selectedPageIDs.insert(page.id)
                    }
                } else {
                    onSelectPageAtIndex(index)
                }
            }

            Text("\(index + 1)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
        }
    }

    private func bottomBarItem(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - 3. Màn Hình Xem Chi Tiết Từng Trang & Vuốt Trái/Phải Chuẩn vFlat (Giống Ảnh 3)

struct VFlatPagePagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var pages: [ScannedBookPage]
    @State var currentIndex: Int
    let folderName: String
    var onTriggerRescan: (RescanMode) -> Void
    var onExportPDF: () -> Void

    @State private var isRunningOCR: Bool = false
    @State private var isShowingOCRResultSheet: Bool = false
    @State private var isShowingCropAndSpineSheet: Bool = false
    @State private var isShowingRescanDialog: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text("\(min(currentIndex + 1, max(1, pages.count))) / \(pages.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if pages.indices.contains(currentIndex), pages[currentIndex].recognizedText != nil {
                    Button {
                        isShowingOCRResultSheet = true
                    } label: {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.white)

            ZStack(alignment: .bottom) {
                Color(white: 0.96).ignoresSafeArea()

                if !pages.isEmpty {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                            Image(uiImage: page.processedImage)
                                .resizable()
                                .scaledToFit()
                                .padding(.horizontal, 12)
                                .padding(.bottom, 58)
                                .tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }

                HStack(spacing: 12) {
                    Button {
                        runOCROnCurrentPage()
                    } label: {
                        HStack(spacing: 8) {
                            if isRunningOCR {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "text.viewfinder")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(isRunningOCR ? "Đang nhận diện chữ..." : "Run Text Recognition")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
                    }
                }
                .padding(.bottom, 16)
            }

            HStack(spacing: 0) {
                pagerBottomButton(icon: "arrow.triangle.2.circlepath.camera", title: "Rescan") {
                    isShowingRescanDialog = true
                }

                pagerBottomButton(icon: "wand.and.stars.inverse", title: "AI Cleanup") {
                    cycleCurrentPageEnhancement()
                }

                pagerBottomButton(icon: "doc.richtext", title: "Create PDF") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onExportPDF()
                    }
                }

                pagerBottomButton(icon: "crop", title: "Crop") {
                    isShowingCropAndSpineSheet = true
                }

                Menu {
                    Button {
                        rotateCurrentPage()
                    } label: {
                        Label("Xoay trang 90°", systemImage: "rotate.right")
                    }

                    if currentIndex > 0 {
                        Button {
                            pages.swapAt(currentIndex, currentIndex - 1)
                            currentIndex -= 1
                        } label: {
                            Label("Đổi chỗ với trang trước", systemImage: "arrow.left")
                        }
                    }

                    if currentIndex < pages.count - 1 {
                        Button {
                            pages.swapAt(currentIndex, currentIndex + 1)
                            currentIndex += 1
                        } label: {
                            Label("Đổi chỗ với trang sau", systemImage: "arrow.right")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteCurrentPage()
                    } label: {
                        Label("Xóa trang này", systemImage: "trash")
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 19))
                        Text("More")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .background(Color.white)
            .overlay(Divider(), alignment: .top)
        }
        .confirmationDialog(
            "Chụp lại (Rescan) trang này",
            isPresented: $isShowingRescanDialog,
            titleVisibility: .visible
        ) {
            if pages.indices.contains(currentIndex) {
                let targetPage = pages[currentIndex]
                Button("Chụp lại 1 trang này (Thay thế Trang \(currentIndex + 1))") {
                    onTriggerRescan(.replaceSinglePage(pageID: targetPage.id))
                }
                Button("Chụp lại cả cặp 2 trang (Tách đôi thay thế tại đây)") {
                    onTriggerRescan(.replaceSpreadPair(pageID: targetPage.id))
                }
            }
            Button("Hủy", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingCropAndSpineSheet) {
            if pages.indices.contains(currentIndex) {
                SpineAndCropAdjustSheet(
                    page: pages[currentIndex],
                    onSave: { updated in
                        if pages.indices.contains(currentIndex) {
                            pages[currentIndex] = updated
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingOCRResultSheet) {
            if pages.indices.contains(currentIndex) {
                OCRTextResultSheet(
                    pageNumber: currentIndex + 1,
                    text: pages[currentIndex].recognizedText ?? ""
                )
            }
        }
    }

    private func pagerBottomButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.black.opacity(0.82))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private func cycleCurrentPageEnhancement() {
        guard pages.indices.contains(currentIndex) else { return }
        let current = pages[currentIndex]
        let nextFilter: EnhancementFilter
        switch current.filter {
        case .cleanBook: nextFilter = .blackAndWhite
        case .blackAndWhite: nextFilter = .original
        case .original: nextFilter = .cleanBook
        }
        pages[currentIndex] = BookSpineProcessor.shared.rebuildSingleSplitPage(
            current,
            newSplitRatio: current.splitRatio,
            newGutterTrimRatio: current.gutterTrimRatio,
            enhancement: nextFilter,
            removeFingers: true
        )
    }

    private func rotateCurrentPage() {
        guard pages.indices.contains(currentIndex) else { return }
        var item = pages[currentIndex]
        item.processedImage = BookSpineProcessor.shared.rotate90Degrees(item.processedImage, clockwise: true)
        item.rotationDegrees = (item.rotationDegrees + 90) % 360
        pages[currentIndex] = item
    }

    private func deleteCurrentPage() {
        guard pages.indices.contains(currentIndex) else { return }
        pages.remove(at: currentIndex)
        if pages.isEmpty {
            dismiss()
        } else if currentIndex >= pages.count {
            currentIndex = pages.count - 1
        }
    }

    private func runOCROnCurrentPage() {
        guard pages.indices.contains(currentIndex), !isRunningOCR else { return }
        isRunningOCR = true
        let targetIdx = currentIndex
        let img = pages[targetIdx].processedImage

        Task {
            let text = await BookSpineProcessor.shared.recognizeText(in: img)
            await MainActor.run {
                if pages.indices.contains(targetIdx) {
                    pages[targetIdx].recognizedText = text.isEmpty
                        ? "(Không tìm thấy văn bản rõ ràng trên trang này)"
                        : text
                }
                isRunningOCR = false
                isShowingOCRResultSheet = true
            }
        }
    }
}

// MARK: - 4. Bảng Chỉnh Vạch Cắt Gáy Sách & Crop

struct SpineAndCropAdjustSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var page: ScannedBookPage
    var onSave: (ScannedBookPage) -> Void

    @State private var splitRatioPercent: Double
    @State private var gutterTrimPercent: Double
    @State private var selectedFilter: EnhancementFilter
    @State private var removeFingers: Bool

    init(page: ScannedBookPage, onSave: @escaping (ScannedBookPage) -> Void) {
        self._page = State(initialValue: page)
        self.onSave = onSave
        self._splitRatioPercent = State(initialValue: Double(page.splitRatio * 100.0))
        self._gutterTrimPercent = State(initialValue: Double(page.gutterTrimRatio * 100.0))
        self._selectedFilter = State(initialValue: page.filter)
        self._removeFingers = State(initialValue: page.removeFingersAtEdges)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(uiImage: page.processedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)

                    if page.sideLabel != .full {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kéo vạch cắt gáy sách (1 | 2)")
                                .font(.subheadline.weight(.bold))

                            GeometryReader { geo in
                                ZStack {
                                    Image(uiImage: page.sourceSpreadImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: geo.size.width, height: geo.size.height)

                                    let splitX = geo.size.width * CGFloat(splitRatioPercent / 100.0)
                                    let trimW = geo.size.width * CGFloat(gutterTrimPercent / 100.0) * 2.0

                                    if trimW > 1 {
                                        Rectangle()
                                            .fill(Color.orange.opacity(0.28))
                                            .frame(width: trimW, height: geo.size.height)
                                            .position(x: splitX, y: geo.size.height / 2.0)
                                    }

                                    Rectangle()
                                        .fill(Color.red)
                                        .frame(width: 2.5, height: geo.size.height)
                                        .position(x: splitX, y: geo.size.height / 2.0)
                                }
                            }
                            .frame(height: 115)
                            .background(Color.black.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            HStack {
                                Text("Vị trí gáy: \(String(format: "%.1f%%", splitRatioPercent))")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 115, alignment: .leading)
                                Slider(value: $splitRatioPercent, in: 35.0...65.0, step: 0.5)
                                    .onChange(of: splitRatioPercent) { _ in rebuildPreview() }
                            }

                            HStack {
                                Text("Cắt rìa gáy: \(String(format: "%.1f%%", gutterTrimPercent))")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 115, alignment: .leading)
                                Slider(value: $gutterTrimPercent, in: 0.0...5.0, step: 0.25)
                                    .onChange(of: gutterTrimPercent) { _ in rebuildPreview() }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Bộ lọc", selection: $selectedFilter) {
                            ForEach(EnhancementFilter.allCases) { f in
                                Text(f.shortName).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedFilter) { _ in rebuildPreview() }

                        Toggle("Khử vết ngón tay giữ ở mép sách", isOn: $removeFingers)
                            .font(.subheadline)
                            .onChange(of: removeFingers) { _ in rebuildPreview() }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                .padding(.top, 12)
            }
            .navigationTitle("Crop & Chỉnh Gáy Sách")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        onSave(page)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func rebuildPreview() {
        page = BookSpineProcessor.shared.rebuildSingleSplitPage(
            page,
            newSplitRatio: CGFloat(splitRatioPercent / 100.0),
            newGutterTrimRatio: CGFloat(gutterTrimPercent / 100.0),
            enhancement: selectedFilter,
            removeFingers: removeFingers
        )
    }
}

// MARK: - 5. Bảng Kết Quả Nhận Diện Văn Bản OCR

struct OCRTextResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pageNumber: Int
    @State var text: String
    @State private var copied: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.body)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Đã chép vào bộ nhớ tạm!" : "Sao chép toàn bộ chữ", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .padding(.top, 10)
            .navigationTitle("Văn bản OCR - Trang \(pageNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}