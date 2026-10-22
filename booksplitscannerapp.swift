import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import PhotosUI
import UIKit

// MARK: - App Version Constant (Tự động đọc bởi GitHub Actions để đặt tên file .ipa)
let APP_VERSION = "2.0.0"

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
    case searchingBook
    case stabilizing(progress: CGFloat) // 0.0 -> 1.0 (Teal fill sweeping up like vFlat)
    case capturing
    case waitingForPageTurn // Sau khi chụp xong 1 lượt, chờ người dùng lật trang mới chụp tiếp
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

/// Tọa độ 4 đỉnh khung trang sách đã chuẩn hóa [0...1] trong hệ tọa độ hiển thị
struct NormalizedQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let defaultBookSpread = NormalizedQuad(
        topLeft: CGPoint(x: 0.08, y: 0.12),
        topRight: CGPoint(x: 0.92, y: 0.12),
        bottomRight: CGPoint(x: 0.92, y: 0.88),
        bottomLeft: CGPoint(x: 0.08, y: 0.88)
    )

    var boundingRect: CGRect {
        let minX = min(topLeft.x, bottomLeft.x)
        let maxX = max(topRight.x, bottomRight.x)
        let minY = min(topLeft.y, topRight.y)
        let maxY = max(bottomLeft.y, bottomRight.y)
        return CGRect(x: minX, y: minY, width: max(0.1, maxX - minX), height: max(0.1, maxY - minY))
    }

    func interpolated(with other: NormalizedQuad, alpha: CGFloat) -> NormalizedQuad {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
        }
        return NormalizedQuad(
            topLeft: lerp(topLeft, other.topLeft),
            topRight: lerp(topRight, other.topRight),
            bottomRight: lerp(bottomRight, other.bottomRight),
            bottomLeft: lerp(bottomLeft, other.bottomLeft)
        )
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

    /// Đảm bảo ảnh trang đôi luôn xoay nằm ngang trước khi cắt đôi
    func ensureLandscapeSpread(_ image: UIImage, isTwoPageMode: Bool) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard isTwoPageMode, normalized.size.height > normalized.size.width * 1.05 else {
            return normalized
        }
        return rotate90Degrees(normalized, clockwise: false)
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

    /// Tự động phát hiện và nắn phẳng 4 góc trang sách bằng Vision + CIPerspectiveCorrection
    func autoCropAndFlattenBook(_ image: UIImage) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return normalized }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 2.2
        request.minimumSize = 0.42
        request.minimumConfidence = 0.65
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let rectObs = request.results?.first else {
            return normalized
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let ciImage = CIImage(cgImage: cgImage)

        let perspective = CIFilter.perspectiveCorrection()
        perspective.inputImage = ciImage
        perspective.topLeft = CGPoint(x: rectObs.topLeft.x * w, y: rectObs.topLeft.y * h)
        perspective.topRight = CGPoint(x: rectObs.topRight.x * w, y: rectObs.topRight.y * h)
        perspective.bottomLeft = CGPoint(x: rectObs.bottomLeft.x * w, y: rectObs.bottomLeft.y * h)
        perspective.bottomRight = CGPoint(x: rectObs.bottomRight.x * w, y: rectObs.bottomRight.y * h)

        guard let outputCI = perspective.outputImage,
              let renderedCG = ciContext.createCGImage(outputCI, from: outputCI.extent) else {
            return normalized
        }
        return UIImage(cgImage: renderedCG, scale: 1.0, orientation: .up)
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

        // Tô viền giấy trắng sạch mỏng (1.8%) ở 3 cạnh ngoài để che vết ngón tay bấm sát mép sách
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
            // Kéo sáng vùng bóng râm ở rãnh gáy sách
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = outputCI
            shadowHighlight.shadowAmount = 0.68
            shadowHighlight.highlightAmount = 0.92
            if let shOut = shadowHighlight.outputImage {
                outputCI = shOut
            }

            // Tăng độ tương phản chữ và làm trắng nền giấy ngả vàng
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = outputCI
            colorControls.contrast = 1.34
            colorControls.brightness = 0.07
            colorControls.saturation = 0.72
            if let ccOut = colorControls.outputImage {
                outputCI = ccOut
            }

            // Làm nét chữ in
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
        removeFingers: Bool = true
    ) -> [ScannedBookPage] {
        return autoreleasepool {
            let groupID = UUID()
            let flattened = autoCropAndFlattenBook(rawShot)
            let spreadImage = ensureLandscapeSpread(flattened, isTwoPageMode: twoPageMode)
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

    /// Xuất PDF (hỗ trợ đính kèm lớp văn bản OCR để tìm kiếm/copy chữ trong PDF)
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

// MARK: - vFlat Real-Time Camera & "No-Tapping" Auto-Capture Controller

final class VFlatCameraController: NSObject, ObservableObject {
    @Published var detectedQuad: NormalizedQuad = .defaultBookSpread
    @Published var isBookDetected: Bool = true
    @Published var autoCaptureEnabled: Bool = true {
        didSet {
            if !autoCaptureEnabled {
                autoStatus = .manualOnly
                autoFillProgress = 0.0
            } else {
                autoStatus = .searchingBook
                autoFillProgress = 0.0
            }
        }
    }
    @Published var autoFillProgress: CGFloat = 0.0
    @Published var autoStatus: AutoCaptureStatus = .searchingBook
    @Published var isTorchOn: Bool = false
    @Published var holdDurationSeconds: Double = 1.15
    @Published var shutterFlashTrigger: Bool = false
    @Published var cameraPermissionDenied: Bool = false

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.personal.booksplit.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.personal.booksplit.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    var onPhotoCaptured: ((UIImage) -> Void)?

    private var previousLumaGrid: [UInt8] = []
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var stableElapsedSeconds: Double = 0
    private var pageTurnMotionFrames: Int = 0
    private var isCapturingPhoto: Bool = false
    private var isSessionConfigured: Bool = false

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
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
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

    func triggerManualCapture() {
        guard !isCapturingPhoto else { return }
        isCapturingPhoto = true
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
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Đặt lại trạng thái chờ lật trang để sẵn sàng chụp ngay lập tức (khi vào chế độ Rescan)
    func armImmediateCapture() {
        videoOutputQueue.async {
            self.stableElapsedSeconds = 0
            self.pageTurnMotionFrames = 0
            DispatchQueue.main.async {
                if self.autoCaptureEnabled {
                    self.autoStatus = .searchingBook
                    self.autoFillProgress = 0
                }
            }
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
        // Phân tích ~10 khung hình/giây để tiết kiệm pin và mượt máy
        guard now - lastFrameTimestamp >= 0.095 else { return }
        let dt = lastFrameTimestamp == 0 ? 0.1 : min(0.35, now - lastFrameTimestamp)
        lastFrameTimestamp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 1. Đo chuyển động khung hình (Motion Delta) trên lưới 32x24 điểm ảnh độ chói (Y-plane)
        let motionScore = computeFrameMotion(pixelBuffer: pixelBuffer)

        // 2. Phát hiện 4 góc trang sách bằng Vision
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.minimumAspectRatio = 0.45
        rectRequest.maximumAspectRatio = 2.2
        rectRequest.minimumSize = 0.35
        rectRequest.minimumConfidence = 0.55
        rectRequest.maximumObservations = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([rectRequest])

        var newQuad: NormalizedQuad = .defaultBookSpread
        var foundBook = true
        if let obs = rectRequest.results?.first {
            newQuad = NormalizedQuad(
                topLeft: CGPoint(x: obs.topLeft.x, y: 1.0 - obs.topLeft.y),
                topRight: CGPoint(x: obs.topRight.x, y: 1.0 - obs.topRight.y),
                bottomRight: CGPoint(x: obs.bottomRight.x, y: 1.0 - obs.bottomRight.y),
                bottomLeft: CGPoint(x: obs.bottomLeft.x, y: 1.0 - obs.bottomLeft.y)
            )
            foundBook = true
        }

        DispatchQueue.main.async {
            self.isBookDetected = foundBook
            self.detectedQuad = self.detectedQuad.interpolated(with: newQuad, alpha: 0.35)

            guard self.autoCaptureEnabled, !self.isCapturingPhoto else { return }

            // Máy trạng thái Auto-Capture không cần chạm tay (giống hệt vFlat):
            // Sau khi chụp xong 1 trang đôi, chờ người dùng lật trang (motionScore > 0.036)
            if self.autoStatus == .waitingForPageTurn {
                if motionScore > 0.034 {
                    self.pageTurnMotionFrames += 1
                    if self.pageTurnMotionFrames >= 2 {
                        self.stableElapsedSeconds = 0
                        self.autoFillProgress = 0
                        self.autoStatus = .searchingBook
                    }
                }
                return
            }

            // Khi trang sách đứng yên (motionScore < 0.017), thanh màu xanh ngọc dâng dần từ 0% -> 100%
            if motionScore < 0.017 {
                self.stableElapsedSeconds += dt
                let progress = min(1.0, max(0.0, CGFloat(self.stableElapsedSeconds / self.holdDurationSeconds)))
                self.autoFillProgress = progress
                self.autoStatus = .stabilizing(progress: progress)

                if progress >= 1.0 {
                    self.stableElapsedSeconds = 0
                    self.pageTurnMotionFrames = 0
                    self.triggerManualCapture()
                }
            } else {
                // Nếu tay đang lật sách hoặc máy rung, tự động hạ thanh đếm về 0
                self.stableElapsedSeconds = max(0.0, self.stableElapsedSeconds - dt * 2.2)
                let progress = min(1.0, max(0.0, CGFloat(self.stableElapsedSeconds / self.holdDurationSeconds)))
                self.autoFillProgress = progress
                self.autoStatus = progress > 0.05 ? .stabilizing(progress: progress) : .searchingBook
            }
        }
    }

    private func computeFrameMotion(pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0.0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)

        let gridW = 32
        let gridH = 24
        var currentGrid = [UInt8](repeating: 0, count: gridW * gridH)

        for gy in 0..<gridH {
            let py = min(height - 1, (gy * height) / gridH + (height / (gridH * 2)))
            let rowPtr = ptr + py * bytesPerRow
            for gx in 0..<gridW {
                let px = min(width - 1, (gx * width) / gridW + (width / (gridW * 2)))
                currentGrid[gy * gridW + gx] = rowPtr[px]
            }
        }

        defer { previousLumaGrid = currentGrid }
        guard previousLumaGrid.count == currentGrid.count else { return 1.0 }

        var diffSum = 0
        for i in 0..<currentGrid.count {
            diffSum += abs(Int(currentGrid[i]) - Int(previousLumaGrid[i]))
        }
        return Double(diffSum) / Double(currentGrid.count * 255)
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
            self.onPhotoCaptured?(image)
        }
    }
}

// MARK: - Live Camera Preview Layer

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
        uiView.updateOrientation()
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateOrientation()
        }

        func updateOrientation() {
            guard let connection = videoPreviewLayer.connection,
                  connection.isVideoOrientationSupported else { return }
            let deviceOrientation = UIDevice.current.orientation
            switch deviceOrientation {
            case .landscapeLeft:
                connection.videoOrientation = .landscapeRight
            case .landscapeRight:
                connection.videoOrientation = .landscapeLeft
            case .portraitUpsideDown:
                connection.videoOrientation = .portraitUpsideDown
            default:
                if bounds.width > bounds.height {
                    connection.videoOrientation = .landscapeRight
                } else {
                    connection.videoOrientation = .portrait
                }
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

// MARK: - Root Container (Switches seamlessly between vFlat Camera & Library Grid)

struct VFlatMainContainerView: View {
    @StateObject private var cameraController = VFlatCameraController()

    @State private var pages: [ScannedBookPage] = []
    @State private var twoPageMode: Bool = true
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
                vFlatLiveCameraScreen
            }

            if let toast = statusToastText {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.top, 16)
                    Spacer()
                }
                .transition(.opacity)
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
            cameraController.onPhotoCaptured = { capturedImage in
                handleCapturedPhoto(capturedImage)
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

    // MARK: - 1. Màn hình Camera Trực Tiếp Chuẩn Giao Diện vFlat (Giống Ảnh 1 & Ảnh 2)

    private var vFlatLiveCameraScreen: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            if isLandscape {
                HStack(spacing: 0) {
                    cameraViewfinderArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    vFlatCameraControlPanel(isLandscape: true)
                        .frame(width: 195)
                        .background(Color.white)
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    cameraViewfinderArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    vFlatCameraControlPanel(isLandscape: false)
                        .frame(height: 195)
                        .background(Color.white)
                }
                .ignoresSafeArea()
            }
        }
    }

    private var cameraViewfinderArea: some View {
        GeometryReader { viewGeo in
            ZStack {
                CameraPreviewLayerView(session: cameraController.session)

                // Khung xanh ngọc nhận diện 2 trang sách + đường đứt nét gáy sách + Số 1 | 2 giống hệt vFlat
                let boxRect = CGRect(
                    x: viewGeo.size.width * 0.08,
                    y: viewGeo.size.height * 0.11,
                    width: viewGeo.size.width * 0.84,
                    height: viewGeo.size.height * 0.78
                )

                ZStack {
                    // Lớp màu xanh ngọc dâng từ dưới lên khi Auto-Capture đang đếm (Giống Ảnh 2)
                    if cameraController.autoFillProgress > 0.01 {
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

                    // Viền xanh ngọc bao quanh 2 trang sách
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(vFlatTeal, lineWidth: 3.2)

                    if twoPageMode {
                        // Đường đứt nét trắng dọc theo gáy sách ở giữa
                        Canvas { ctx, size in
                            var path = Path()
                            path.move(to: CGPoint(x: size.width / 2.0, y: -12))
                            path.addLine(to: CGPoint(x: size.width / 2.0, y: size.height + 12))
                            ctx.stroke(
                                path,
                                with: .color(.white),
                                style: StrokeStyle(lineWidth: 3.0, lineCap: .round, dash: [10, 8])
                            )
                        }

                        // Chữ số 1 và 2 bán trong suốt ở giữa trang Trái & Phải
                        HStack(spacing: 0) {
                            Text(readingDirection == .leftToRight ? "1" : "2")
                                .font(.system(size: 86, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.32))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            Text(readingDirection == .leftToRight ? "2" : "1")
                                .font(.system(size: 86, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.32))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        Text("1")
                            .font(.system(size: 86, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.32))
                    }
                }
                .frame(width: boxRect.width, height: boxRect.height)
                .position(x: boxRect.midX, y: boxRect.midY)

                // Nhãn hướng dẫn trạng thái Auto-Capture trên kính ngắm
                VStack {
                    HStack {
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
                                .background(Color.orange.opacity(0.9))
                                .clipShape(Capsule())
                            }
                        } else {
                            statusBadgeOnViewfinder
                        }
                        Spacer()
                    }
                    .padding(16)
                    Spacer()
                }

                // Hiệu ứng chớp màn trập khi chụp
                if cameraController.shutterFlashTrigger {
                    Color.white.opacity(0.65)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private var statusBadgeOnViewfinder: some View {
        let labelText: String
        let badgeColor: Color

        switch cameraController.autoStatus {
        case .manualOnly:
            labelText = "Chế độ chụp tay (Bấm nút tròn hoặc bật AUTO)"
            badgeColor = .black.opacity(0.55)
        case .searchingBook:
            labelText = "AUTO: Giữ trang sách phẳng & đứng yên để tự chụp..."
            badgeColor = .black.opacity(0.55)
        case .stabilizing(let progress):
            labelText = "Đang tự chụp... \(Int(progress * 100))%"
            badgeColor = Color(red: 0.08, green: 0.62, blue: 0.52).opacity(0.88)
        case .capturing:
            labelText = "Đang tách 2 trang..."
            badgeColor = .blue.opacity(0.85)
        case .waitingForPageTurn:
            labelText = "Đã lưu! Hãy lật sang trang tiếp theo (Không cần bấm nút)"
            badgeColor = Color.green.opacity(0.82)
        }

        return Text(labelText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(badgeColor)
            .clipShape(Capsule())
    }

    /// Bảng điều khiển trắng của Camera giống hệt Ảnh 1 & Ảnh 2 của vFlat
    private func vFlatCameraControlPanel(isLandscape: Bool) -> some View {
        Group {
            if isLandscape {
                HStack(spacing: 8) {
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
                    .padding(.vertical, 20)
                    .frame(width: 46)

                    // Cột giữa & phải: Nút Library ở trên, Nút chụp tròn lớn ở giữa, Thumbnail + Tên thư mục ở dưới
                    VStack(spacing: 14) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShowingLibrary = true
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 22, weight: .medium))
                                Text("Library")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(Color.black.opacity(0.75))
                        }
                        .padding(.top, 18)

                        Spacer()

                        // Nút chụp tròn lớn chuẩn vFlat
                        Button {
                            cameraController.triggerManualCapture()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.gray.opacity(0.38), lineWidth: 5)
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

                        // Thumbnail trang vừa quét & thanh tên thư mục
                        HStack(spacing: 10) {
                            latestThumbnailButton
                            folderPillButton
                        }
                        .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 8)
            } else {
                // Bố cục khi cầm dọc điện thoại
                VStack(spacing: 12) {
                    // Hàng trên: 5 nút tính năng nhanh (More, AUTO, Timer, Flash, [1|2])
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

                    // Hàng dưới: Library — Nút chụp tròn — Thumbnail
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
                                    .stroke(Color.gray.opacity(0.38), lineWidth: 5)
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
        }
    }

    // Các nút điều khiển nhỏ trên bảng Camera vFlat
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
                Toggle("Tự xóa ngón tay ở mép sách", isOn: $removeFingersAtEdges)
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
            if cameraController.holdDurationSeconds < 1.2 {
                cameraController.holdDurationSeconds = 1.8
                showToast("Tốc độ tự chụp: 1.8 giây")
            } else if cameraController.holdDurationSeconds < 2.0 {
                cameraController.holdDurationSeconds = 2.5
                showToast("Tốc độ tự chụp: 2.5 giây")
            } else {
                cameraController.holdDurationSeconds = 1.0
                showToast("Tốc độ tự chụp nhanh: 1.0 giây")
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
            twoPageMode.toggle()
            showToast(twoPageMode ? "Chế độ: Quét & Tách 2 Trang [1|2]" : "Chế độ: Quét 1 Trang Đơn")
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
                        .frame(width: 48, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 48, height: 62)
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
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    // MARK: - Xử lý ảnh vừa chụp (Tự động tách 2 trang ngầm không làm gián đoạn việc lật sách)

    private func handleCapturedPhoto(_ rawImage: UIImage) {
        isProcessingShot = true
        let currentMode = rescanMode
        let isTwoPage = twoPageMode
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
                    removeFingers: currentRemoveFingers
                )
                await MainActor.run {
                    self.pages.append(contentsOf: newSplitPages)
                    self.isProcessingShot = false
                    self.showToast(isTwoPage ? "Đã tự tách +2 trang (Tổng: \(self.pages.count))" : "Đã thêm +1 trang (Tổng: \(self.pages.count))")
                }

            case .replaceSinglePage(let targetID):
                let flattened = BookSpineProcessor.shared.autoCropAndFlattenBook(rawImage)
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
                    removeFingers: currentRemoveFingers
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
            // Thanh tiêu đề trên cùng giống Ảnh 4 (Mũi tên quay lại, Tên thư mục, Tìm kiếm & Menu)
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

            // Lưới hiển thị các trang sách + Nút tròn xanh lá mở Camera ở góc dưới phải (Giống Ảnh 4)
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

                // Nút tròn xanh ngọc mở Camera quét tiếp (Giống hệt Ảnh 4)
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

            // Thanh 5 công cụ dưới đáy chuẩn vFlat (Create PDF | AI Cleanup | Delete | Import | More)
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

            // Số thứ tự trang rõ ràng bên dưới giống hệt Ảnh 4 (10, 11, 12, 13...)
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
            // Thanh tiêu đề trên cùng giống Ảnh 3: Mũi tên quay lại + Tên thư mục & "16 / 16"
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

            // Vùng vuốt xem từng trang + Nút nổi "[T] Run Text Recognition" giống hệt Ảnh 3
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

                // Nút nổi "[T] Run Text Recognition" ngay phía trên thanh công cụ dưới (Giống Ảnh 3)
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

            // Thanh 5 nút dưới đáy giống hệt Ảnh 3: Rescan | AI Cleanup | Create PDF | Crop | More
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

// MARK: - 4. Bảng Chỉnh Vạch Cắt Gáy Sách & Crop (Khi bấm nút Crop ở Ảnh 3)

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

// MARK: - 5. Bảng Kết Quả Nhận Diện Văn Bản OCR (Run Text Recognition)

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
