import SwiftUI
import VisionKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import PhotosUI
import UIKit

// MARK: - App Entry Point
@main
struct BookSplitScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Models & Enums

enum SplitMode: String, CaseIterable, Identifiable {
    case alwaysSplit = "Luôn tách 2 trang"
    case autoLandscape = "Tự động (Ảnh ngang)"
    case singlePage = "Không tách (1 trang)"

    var id: String { rawValue }
}

enum ReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight = "Trái → Phải (Sách thường)"
    case rightToLeft = "Phải → Trái (Manga/Sách cổ)"

    var id: String { rawValue }
}

enum EnhancementFilter: String, CaseIterable, Identifiable {
    case cleanBook = "Làm rõ chữ & Trắng giấy"
    case original = "Ảnh gốc sắc nét"
    case blackAndWhite = "Đen trắng tương phản cao"

    var id: String { rawValue }
}

enum PageSideLabel: String {
    case left = "Trang Trái"
    case right = "Trang Phải"
    case full = "Nguyên Trang"
}

struct ScannedBookPage: Identifiable, Equatable {
    let id: UUID
    var sourceSpreadImage: UIImage
    var processedImage: UIImage
    var sideLabel: PageSideLabel
    var splitRatio: CGFloat
    var gutterTrimRatio: CGFloat
    var rotationDegrees: Int

    init(
        id: UUID = UUID(),
        sourceSpreadImage: UIImage,
        processedImage: UIImage,
        sideLabel: PageSideLabel,
        splitRatio: CGFloat = 0.5,
        gutterTrimRatio: CGFloat = 0.015,
        rotationDegrees: Int = 0
    ) {
        self.id = id
        self.sourceSpreadImage = sourceSpreadImage
        self.processedImage = processedImage
        self.sideLabel = sideLabel
        self.splitRatio = splitRatio
        self.gutterTrimRatio = gutterTrimRatio
        self.rotationDegrees = rotationDegrees
    }

    static func == (lhs: ScannedBookPage, rhs: ScannedBookPage) -> Bool {
        lhs.id == rhs.id &&
        lhs.splitRatio == rhs.splitRatio &&
        lhs.gutterTrimRatio == rhs.gutterTrimRatio &&
        lhs.rotationDegrees == rhs.rotationDegrees &&
        lhs.sideLabel == rhs.sideLabel
    }
}

// MARK: - Book Spine Detection & Image Processing Engine

final class BookSpineProcessor {
    static let shared = BookSpineProcessor()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Chuẩn hóa hướng ảnh (Orientation = .up) để tọa độ cắt CGImage luôn chính xác tuyệt đối
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

    /// Tự động xoay ảnh chụp dọc thành ảnh ngang nếu người dùng cầm dọc điện thoại khi chụp 2 trang sách
    func ensureSpreadOrientation(_ image: UIImage, forceLandscapeForSpread: Bool) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard forceLandscapeForSpread, normalized.size.height > normalized.size.width * 1.12 else {
            return normalized
        }
        return rotate90Degrees(normalized, clockwise: false)
    }

    /// Xoay ảnh theo bội số 90 độ
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

    /// Thuật toán tự động dò vị trí gáy sách (Spine Detection) trong vùng trung tâm [38% ... 62%]
    /// Kết hợp phân tích bóng tối dọc ở rãnh gáy sách và mật độ khoảng trắng giữa 2 cột chữ
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

        // Tìm giá trị trung bình của vùng giữa để chuẩn hóa
        var bestX = analysisWidth / 2
        var lowestScore = Double.greatestFiniteMagnitude
        let center = Double(analysisWidth) * 0.5

        for x in (minX + 2)...(maxX - 2) {
            // Làm mượt 5 cột lân cận
            var smoothBrightness = 0.0
            var smoothTextEnergy = 0.0
            for dx in -2...2 {
                smoothBrightness += columnMeanBrightness[x + dx]
                smoothTextEnergy += columnVerticalEdgeEnergy[x + dx]
            }
            smoothBrightness /= 5.0
            smoothTextEnergy /= 5.0

            // Rãnh gáy sách thường tối hơn nền giấy (smoothBrightness thấp)
            // và ít cắt ngang dòng chữ hơn (smoothTextEnergy thấp)
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

    /// Áp dụng bộ lọc làm nét chữ và làm trắng trang sách bằng CoreImage
    func applyEnhancement(_ image: UIImage, filter: EnhancementFilter) -> UIImage {
        let normalized = normalizeOrientation(image)
        guard filter != .original, let cgImage = normalized.cgImage else {
            return normalized
        }

        let ciImage = CIImage(cgImage: cgImage)
        var outputCI = ciImage

        switch filter {
        case .original:
            return normalized

        case .cleanBook:
            // Làm sáng vùng bóng mờ ở gáy sách
            let shadowHighlight = CIFilter.highlightShadowAdjust()
            shadowHighlight.inputImage = outputCI
            shadowHighlight.shadowAmount = 0.55
            shadowHighlight.highlightAmount = 0.95
            if let shOut = shadowHighlight.outputImage {
                outputCI = shOut
            }

            // Tăng độ tương phản và làm trắng nền giấy
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = outputCI
            colorControls.contrast = 1.28
            colorControls.brightness = 0.05
            colorControls.saturation = 0.85
            if let ccOut = colorControls.outputImage {
                outputCI = ccOut
            }

            // Làm sắc nét nét chữ
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = outputCI
            unsharp.radius = 1.6
            unsharp.intensity = 0.75
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
            colorControls.contrast = 1.42
            colorControls.brightness = 0.08
            colorControls.saturation = 0.0
            if let ccOut = colorControls.outputImage {
                outputCI = ccOut
            }

            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = outputCI
            sharpen.sharpness = 0.6
            if let shOut = sharpen.outputImage {
                outputCI = shOut
            }
        }

        guard let renderedCG = ciContext.createCGImage(outputCI, from: ciImage.extent) else {
            return normalized
        }
        return UIImage(cgImage: renderedCG, scale: 1.0, orientation: .up)
    }

    /// Cắt 1 ảnh chụp trang đôi thành 2 trang sách riêng biệt (Trái & Phải)
    func splitBookSpread(
        _ rawSpreadImage: UIImage,
        splitMode: SplitMode,
        readingDirection: ReadingDirection,
        enhancement: EnhancementFilter,
        customSplitRatio: CGFloat? = nil,
        gutterTrimRatio: CGFloat = 0.015,
        autoRotatePortraitSpread: Bool = true
    ) -> [ScannedBookPage] {
        return autoreleasepool {
            let spreadImage = ensureSpreadOrientation(
                rawSpreadImage,
                forceLandscapeForSpread: (splitMode == .alwaysSplit && autoRotatePortraitSpread)
            )
            guard let cgImage = spreadImage.cgImage else { return [] }

            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)

            let shouldSplit: Bool
            switch splitMode {
            case .alwaysSplit:
                shouldSplit = true
            case .autoLandscape:
                shouldSplit = width >= height * 0.88
            case .singlePage:
                shouldSplit = false
            }

            if !shouldSplit {
                let enhanced = applyEnhancement(spreadImage, filter: enhancement)
                return [
                    ScannedBookPage(
                        sourceSpreadImage: spreadImage,
                        processedImage: enhanced,
                        sideLabel: .full,
                        splitRatio: 0.5,
                        gutterTrimRatio: 0.0
                    )
                ]
            }

            let splitRatio = customSplitRatio ?? detectSpineSplitRatio(in: cgImage)
            let splitX = width * splitRatio
            let trimPx = width * min(max(gutterTrimRatio, 0.0), 0.06)

            let leftWidth = max(1.0, splitX - trimPx)
            let rightStartX = min(width - 1.0, splitX + trimPx)
            let rightWidth = max(1.0, width - rightStartX)

            let leftRect = CGRect(x: 0, y: 0, width: leftWidth, height: height).integral
            let rightRect = CGRect(x: rightStartX, y: 0, width: rightWidth, height: height).integral

            var resultPages: [ScannedBookPage] = []

            var leftPage: ScannedBookPage?
            var rightPage: ScannedBookPage?

            if let leftCG = cgImage.cropping(to: leftRect) {
                let rawLeft = UIImage(cgImage: leftCG, scale: 1.0, orientation: .up)
                let enhancedLeft = applyEnhancement(rawLeft, filter: enhancement)
                leftPage = ScannedBookPage(
                    sourceSpreadImage: spreadImage,
                    processedImage: enhancedLeft,
                    sideLabel: .left,
                    splitRatio: splitRatio,
                    gutterTrimRatio: gutterTrimRatio
                )
            }

            if let rightCG = cgImage.cropping(to: rightRect) {
                let rawRight = UIImage(cgImage: rightCG, scale: 1.0, orientation: .up)
                let enhancedRight = applyEnhancement(rawRight, filter: enhancement)
                rightPage = ScannedBookPage(
                    sourceSpreadImage: spreadImage,
                    processedImage: enhancedRight,
                    sideLabel: .right,
                    splitRatio: splitRatio,
                    gutterTrimRatio: gutterTrimRatio
                )
            }

            switch readingDirection {
            case .leftToRight:
                if let leftPage { resultPages.append(leftPage) }
                if let rightPage { resultPages.append(rightPage) }
            case .rightToLeft:
                if let rightPage { resultPages.append(rightPage) }
                if let leftPage { resultPages.append(leftPage) }
            }

            return resultPages
        }
    }

    /// Tái tạo lại 1 trang đơn lẻ khi người dùng kéo thanh trượt chỉnh lại đường cắt gáy sách
    func rebuildSingleSplitPage(
        _ page: ScannedBookPage,
        newSplitRatio: CGFloat,
        newGutterTrimRatio: CGFloat,
        enhancement: EnhancementFilter
    ) -> ScannedBookPage {
        guard page.sideLabel != .full,
              let cgImage = page.sourceSpreadImage.cgImage else {
            return page
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
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
        let rawCropped = UIImage(cgImage: croppedCG, scale: 1.0, orientation: .up)
        let enhanced = applyEnhancement(rawCropped, filter: enhancement)

        var updated = page
        updated.processedImage = enhanced
        updated.splitRatio = newSplitRatio
        updated.gutterTrimRatio = newGutterTrimRatio
        return updated
    }

    /// Xuất danh sách trang sách ra file PDF chất lượng cao
    func generatePDF(from pages: [ScannedBookPage], fileName: String, fitStandardA4: Bool) -> URL? {
        guard !pages.isEmpty else { return nil }

        let safeName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Sach_Scan_\(Int(Date().timeIntervalSince1970))"
            : fileName.trimmingCharacters(in: .whitespacesAndNewlines)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).pdf")

        // Kích thước A4 ở 150 DPI (1240 x 1754 pt)
        let a4Rect = CGRect(x: 0, y: 0, width: 1240, height: 1754)
        let renderer = UIGraphicsPDFRenderer(bounds: a4Rect)

        do {
            try renderer.writePDF(to: outputURL) { context in
                for page in pages {
                    autoreleasepool {
                        let img = page.processedImage
                        let imgSize = img.size
                        guard imgSize.width > 0, imgSize.height > 0 else { return }

                        if fitStandardA4 {
                            context.beginPage(withBounds: a4Rect, pageInfo: [:])
                            UIColor.white.setFill()
                            context.fill(a4Rect)

                            let margin: CGFloat = 24.0
                            let availableRect = a4Rect.insetBy(dx: margin, dy: margin)
                            let scale = min(
                                availableRect.width / imgSize.width,
                                availableRect.height / imgSize.height
                            )
                            let drawWidth = imgSize.width * scale
                            let drawHeight = imgSize.height * scale
                            let drawRect = CGRect(
                                x: availableRect.minX + (availableRect.width - drawWidth) / 2.0,
                                y: availableRect.minY + (availableRect.height - drawHeight) / 2.0,
                                width: drawWidth,
                                height: drawHeight
                            )
                            img.draw(in: drawRect)
                        } else {
                            let pageBounds = CGRect(origin: .zero, size: imgSize)
                            context.beginPage(withBounds: pageBounds, pageInfo: [:])
                            img.draw(in: pageBounds)
                        }
                    }
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }
}

// MARK: - Native iOS VisionKit Document Camera Wrapper

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanCompleted: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var scannedImages: [UIImage] = []
            for pageIndex in 0..<scan.pageCount {
                scannedImages.append(scan.imageOfPage(at: pageIndex))
            }
            controller.dismiss(animated: true) {
                self.parent.onScanCompleted(scannedImages)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) {
                self.parent.onError(error.localizedDescription)
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

// MARK: - Main ContentView

struct ContentView: View {
    @State private var pages: [ScannedBookPage] = []
    @State private var splitMode: SplitMode = .alwaysSplit
    @State private var readingDirection: ReadingDirection = .leftToRight
    @State private var enhancementFilter: EnhancementFilter = .cleanBook
    @State private var gutterTrimPercent: Double = 1.5
    @State private var autoRotatePortraitSpread: Bool = true
    @State private var fitStandardA4PDF: Bool = false
    @State private var bookTitle: String = "Sach_Scan"

    @State private var isShowingScanner = false
    @State private var isProcessing = false
    @State private var processingProgressText = "Đang tách trang & làm nét chữ..."
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    @State private var selectedPageForEdit: ScannedBookPage?
    @State private var exportedPDFURL: URL?
    @State private var isShowingShareSheet = false
    @State private var alertMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                settingsHeaderBar

                if isProcessing {
                    processingBanner
                }

                if pages.isEmpty {
                    emptyStateView
                } else {
                    scannedPagesGridView
                }

                bottomActionBar
            }
            .navigationTitle("BookSplit Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !pages.isEmpty {
                        Button(role: .destructive) {
                            pages.removeAll()
                        } label: {
                            Label("Xóa hết", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !pages.isEmpty {
                        Button {
                            exportAllToPDF()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.richtext.fill")
                                Text("Xuất PDF (\(pages.count))")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $isShowingScanner) {
                DocumentScannerView(
                    onScanCompleted: { rawImages in
                        processIncomingSpreads(rawImages)
                    },
                    onCancel: {},
                    onError: { errMsg in
                        alertMessage = "Không thể mở Camera quét tài liệu: \(errMsg)"
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $selectedPageForEdit) { page in
                PageDetailEditorSheet(
                    page: page,
                    enhancementFilter: enhancementFilter,
                    onSave: { updatedPage in
                        if let idx = pages.firstIndex(where: { $0.id == updatedPage.id }) {
                            pages[idx] = updatedPage
                        }
                    },
                    onDelete: { pageToDelete in
                        pages.removeAll { $0.id == pageToDelete.id }
                    }
                )
            }
            .sheet(isPresented: $isShowingShareSheet) {
                if let url = exportedPDFURL {
                    ActivityShareSheet(items: [url])
                }
            }
            .alert("Thông báo", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("Đóng", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .onChange(of: selectedPhotoItems) { newItems in
                guard !newItems.isEmpty else { return }
                loadImagesFromPhotoPicker(newItems)
            }
        }
    }

    // MARK: - Subviews

    private var settingsHeaderBar: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Menu {
                        Picker("Chế độ tách", selection: $splitMode) {
                            ForEach(SplitMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    } label: {
                        chipLabel(icon: "book.pages", title: splitMode.rawValue)
                    }

                    Menu {
                        Picker("Thứ tự trang", selection: $readingDirection) {
                            ForEach(ReadingDirection.allCases) { dir in
                                Text(dir.rawValue).tag(dir)
                            }
                        }
                    } label: {
                        chipLabel(icon: "arrow.left.arrow.right", title: readingDirection.rawValue)
                    }

                    Menu {
                        Picker("Bộ lọc làm nét", selection: $enhancementFilter) {
                            ForEach(EnhancementFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        chipLabel(icon: "wand.and.stars", title: enhancementFilter.rawValue)
                    }

                    Toggle(isOn: $autoRotatePortraitSpread) {
                        Label("Tự xoay ngang khi chụp", systemImage: "rotate.right")
                            .font(.caption.weight(.medium))
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 12) {
                Image(systemName: "scissors")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Cắt rìa gáy: \(String(format: "%.1f%%", gutterTrimPercent))")
                    .font(.caption.weight(.medium))
                    .frame(width: 110, alignment: .leading)
                Slider(value: $gutterTrimPercent, in: 0.0...4.5, step: 0.5)
                Toggle("Khổ A4", isOn: $fitStandardA4PDF)
                    .font(.caption.weight(.medium))
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func chipLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }

    private var processingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(processingProgressText)
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.1))
    }

    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "book.and.wrench.fill")
                .font(.system(size: 62))
                .foregroundStyle(Color.accentColor)

            Text("Quét & Tách Đôi 2 Trang Sách Tự Động")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                featureRow(
                    icon: "camera.viewfinder",
                    text: "Sử dụng Camera gốc sắc nét của iPhone: tự động bắt viền trang sách, chụp liên tiếp nhiều trang và làm phẳng góc nghiêng."
                )
                featureRow(
                    icon: "scissors.badge.ellipsis",
                    text: "Tự động dò đường gáy sách ở giữa để tách 1 ảnh chụp thành 2 trang rời (Trang Trái & Trang Phải) theo đúng thứ tự đọc."
                )
                featureRow(
                    icon: "doc.text.magnifyingglass",
                    text: "Khử bóng tối ở rãnh gáy sách, làm trắng nền giấy và xuất file PDF độ phân giải cao."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .padding()
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var scannedPagesGridView: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(.secondary)
                    TextField("Tên file PDF khi xuất", text: $bookTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                    Text("(\(pages.count) trang)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        pageCard(index: index, page: page)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private func pageCard(index: Int, page: ScannedBookPage) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: page.processedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                HStack(spacing: 4) {
                    Text("Trang \(index + 1)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                    Text(page.sideLabel.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            page.sideLabel == .left ? Color.blue.opacity(0.85) :
                            (page.sideLabel == .right ? Color.indigo.opacity(0.85) : Color.gray.opacity(0.85))
                        )
                        .clipShape(Capsule())
                }
                .padding(8)
            }
            .onTapGesture {
                selectedPageForEdit = page
            }

            HStack(spacing: 14) {
                Button {
                    rotatePageAt(index: index)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    selectedPageForEdit = page
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Chỉnh gáy")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Button(role: .destructive) {
                    pages.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button {
                if VNDocumentCameraViewController.isSupported {
                    isShowingScanner = true
                } else {
                    alertMessage = "Thiết bị này không hỗ trợ Camera quét tài liệu VisionKit. Vui lòng chọn ảnh từ Thư viện."
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.headline)
                    Text("Quét Sách (Tự Tách 2 Trang)")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: 50,
                matching: .images
            ) {
                VStack(spacing: 2) {
                    Image(systemName: "photo.stack.fill")
                        .font(.headline)
                    Text("Thư viện")
                        .font(.caption2.weight(.semibold))
                }
                .frame(width: 76)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Actions & Logic

    private func processIncomingSpreads(_ rawSpreads: [UIImage]) {
        guard !rawSpreads.isEmpty else { return }
        isProcessing = true
        let currentSplitMode = splitMode
        let currentDirection = readingDirection
        let currentFilter = enhancementFilter
        let currentTrim = CGFloat(gutterTrimPercent / 100.0)
        let currentAutoRotate = autoRotatePortraitSpread

        Task.detached(priority: .userInitiated) {
            var generatedPages: [ScannedBookPage] = []
            for (idx, spread) in rawSpreads.enumerated() {
                await MainActor.run {
                    self.processingProgressText = "Đang tách trang đôi \(idx + 1)/\(rawSpreads.count)..."
                }
                let splitResult = BookSpineProcessor.shared.splitBookSpread(
                    spread,
                    splitMode: currentSplitMode,
                    readingDirection: currentDirection,
                    enhancement: currentFilter,
                    customSplitRatio: nil,
                    gutterTrimRatio: currentTrim,
                    autoRotatePortraitSpread: currentAutoRotate
                )
                generatedPages.append(contentsOf: splitResult)
            }

            await MainActor.run {
                self.pages.append(contentsOf: generatedPages)
                self.isProcessing = false
            }
        }
    }

    private func loadImagesFromPhotoPicker(_ items: [PhotosPickerItem]) {
        isProcessing = true
        processingProgressText = "Đang tải ảnh từ thư viện..."

        Task {
            var loadedImages: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    loadedImages.append(image)
                }
            }
            await MainActor.run {
                selectedPhotoItems.removeAll()
                if loadedImages.isEmpty {
                    isProcessing = false
                } else {
                    processIncomingSpreads(loadedImages)
                }
            }
        }
    }

    private func rotatePageAt(index: Int) {
        guard pages.indices.contains(index) else { return }
        var item = pages[index]
        item.processedImage = BookSpineProcessor.shared.rotate90Degrees(item.processedImage, clockwise: true)
        item.rotationDegrees = (item.rotationDegrees + 90) % 360
        pages[index] = item
    }

    private func exportAllToPDF() {
        guard !pages.isEmpty else { return }
        isProcessing = true
        processingProgressText = "Đang đóng gói file PDF độ phân giải cao..."
        let snapshotPages = pages
        let title = bookTitle
        let useA4 = fitStandardA4PDF

        Task.detached(priority: .userInitiated) {
            let pdfURL = BookSpineProcessor.shared.generatePDF(
                from: snapshotPages,
                fileName: title,
                fitStandardA4: useA4
            )
            await MainActor.run {
                self.isProcessing = false
                if let pdfURL {
                    self.exportedPDFURL = pdfURL
                    self.isShowingShareSheet = true
                } else {
                    self.alertMessage = "Không thể tạo file PDF. Vui lòng thử lại."
                }
            }
        }
    }
}

// MARK: - Interactive Spine Adjustment & Page Preview Sheet

struct PageDetailEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var page: ScannedBookPage
    let enhancementFilter: EnhancementFilter
    var onSave: (ScannedBookPage) -> Void
    var onDelete: (ScannedBookPage) -> Void

    @State private var splitRatioSlider: Double
    @State private var gutterTrimSlider: Double

    init(
        page: ScannedBookPage,
        enhancementFilter: EnhancementFilter,
        onSave: @escaping (ScannedBookPage) -> Void,
        onDelete: @escaping (ScannedBookPage) -> Void
    ) {
        self._page = State(initialValue: page)
        self.enhancementFilter = enhancementFilter
        self.onSave = onSave
        self.onDelete = onDelete
        self._splitRatioSlider = State(initialValue: Double(page.splitRatio * 100.0))
        self._gutterTrimSlider = State(initialValue: Double(page.gutterTrimRatio * 100.0))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Xem trước trang đã cắt
                Image(uiImage: page.processedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 380)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                if page.sideLabel != .full {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tinh chỉnh vị trí đường cắt gáy sách")
                            .font(.subheadline.weight(.bold))

                        // Ảnh spread gốc kèm vạch đỏ hiển thị vị trí cắt
                        GeometryReader { geo in
                            ZStack {
                                Image(uiImage: page.sourceSpreadImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geo.size.width, height: geo.size.height)

                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 2.5, height: geo.size.height)
                                    .position(
                                        x: geo.size.width * CGFloat(splitRatioSlider / 100.0),
                                        y: geo.size.height / 2.0
                                    )
                            }
                        }
                        .frame(height: 110)
                        .background(Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack {
                            Text("Vị trí gáy: \(String(format: "%.1f%%", splitRatioSlider))")
                                .font(.caption.weight(.semibold))
                                .frame(width: 115, alignment: .leading)
                            Slider(value: $splitRatioSlider, in: 35.0...65.0, step: 0.5)
                                .onChange(of: splitRatioSlider) { _ in
                                    recalculateCrop()
                                }
                        }

                        HStack {
                            Text("Cắt rìa gáy: \(String(format: "%.1f%%", gutterTrimSlider))")
                                .font(.caption.weight(.semibold))
                                .frame(width: 115, alignment: .leading)
                            Slider(value: $gutterTrimSlider, in: 0.0...5.0, step: 0.25)
                                .onChange(of: gutterTrimSlider) { _ in
                                    recalculateCrop()
                                }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                }

                HStack(spacing: 16) {
                    Button {
                        page.processedImage = BookSpineProcessor.shared.rotate90Degrees(
                            page.processedImage,
                            clockwise: true
                        )
                    } label: {
                        Label("Xoay 90°", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        onDelete(page)
                        dismiss()
                    } label: {
                        Label("Xóa trang này", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle(page.sideLabel.rawValue)
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

    private func recalculateCrop() {
        page = BookSpineProcessor.shared.rebuildSingleSplitPage(
            page,
            newSplitRatio: CGFloat(splitRatioSlider / 100.0),
            newGutterTrimRatio: CGFloat(gutterTrimSlider / 100.0),
            enhancement: enhancementFilter
        )
    }
}