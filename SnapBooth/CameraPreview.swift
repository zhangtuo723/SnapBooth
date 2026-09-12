import AVFoundation
import SwiftUI
import UIKit
import Combine
import Photos
import ImageIO
import UniformTypeIdentifiers


private struct HomePageSettings: Codable {
    var symbol: String
    var eyebrow: String
    var title: String
    var subtitle: String
    var buttonTitle: String

    static let generic = HomePageSettings(
        symbol: "✦",
        eyebrow: "WELCOME TO YOUR MOMENT",
        title: "欢迎来到 SnapBooth",
        subtitle: "定格此刻 · 留住回忆",
        buttonTitle: "开始拍摄"
    )

    static func load() -> HomePageSettings {
        guard let data = UserDefaults.standard.data(forKey: "SnapBooth.HomePageSettings"),
              let settings = try? JSONDecoder().decode(HomePageSettings.self, from: data) else {
            return .generic
        }
        return settings
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "SnapBooth.HomePageSettings")
    }
}

private enum HomePageBackgroundStore {
    static var url: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SnapBooth", isDirectory: true)
            .appendingPathComponent("HomeBackground.jpg")
    }

    static func load() -> UIImage? {
        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func save(_ image: UIImage?) throws {
        guard let url else { return }
        if let image {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = image.jpegData(compressionQuality: 0.92) else { return }
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        DispatchQueue.main.async { view.videoPreviewLayer.session = session }
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Reassigning a running session during SwiftUI layout can synchronously
        // invalidate the preview and re-enter AttributeGraph on Mac Catalyst.
        // The session identity is fixed for this view's lifetime. Never mutate
        // AVFoundation connections inside a SwiftUI update/layout transaction.
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct MacBoothView: UIViewControllerRepresentable {
    let camera: CameraService
    let printer: PrinterService
    func makeUIViewController(context: Context) -> MacBoothController {
        MacBoothController(camera: camera, printer: printer)
    }
    func updateUIViewController(_ controller: MacBoothController, context: Context) {}
}

/// Stable native view hierarchy: retaking only hides the photo overlay.
/// AVFoundation preview connections never participate in SwiftUI layout.
final class MacBoothController: UIViewController, UIDocumentPickerDelegate {
    private let camera: CameraService
    private let printer: PrinterService
    private let live = PreviewView()
    private let photo = UIImageView()
    private let status = UILabel()
    private let printerStatus = UILabel()
    private let cameraButton = UIButton(type: .system)
    private let recoverCameraPhoto = UIButton(type: .system)
    private let shutter = UIButton(type: .system)
    private let retake = UIButton(type: .system)
    private let printButton = UIButton(type: .system)
    private let saveStatus = UILabel()
    private var saving = false
    private let printerChoice = UIButton(type: .system)
    private let layout = UISegmentedControl(items: PhotoLayout.allCases.map(\.rawValue))
    private let mode = UISegmentedControl(items: PrinterService.Mode.available.map(\.rawValue))
    private let aspect = UISegmentedControl(items: PhotoAspect.allCases.map(\.rawValue))
    private let filter = UISegmentedControl(items: PhotoFilter.allCases.map(\.rawValue))
    private let frame = UISegmentedControl(items: PhotoFrame.allCases.map(\.rawValue))
    private let strength = UISlider()
    private let paper = UIButton(type: .system)
    private var selectedPaper = PaperSize.xiaomiSix
    private let sizeInfo = UILabel()
    private let paperSettings = UIStackView()
    private let direction = UISegmentedControl(items: PaperDirection.allCases.map(\.rawValue))
    private let placement = UISegmentedControl(items: PhotoPlacement.allCases.map(\.rawValue))
    private let printSize = UISegmentedControl(items: PhotoPrintSize.allCases.map(\.rawValue))
    private let rotation = UISegmentedControl(items: ["0°", "90°", "180°", "270°"])
    private let timer = UISegmentedControl(items: ["即拍", "3 秒", "5 秒", "10 秒"])
    private let stage = UIView()
    private let stageLabel = UILabel()
    private let shooting = UIStackView()
    private let actionButtons = UIStackView()
    private let toolbarSpacer = UIView()
    private let countdownLabel = UILabel()
    private let loadingOverlay = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let loadingTitle = UILabel()
    private let loadingDetail = UILabel()
    private let editorState = UILabel()
    private let root = UIStackView()
    private let scroll = UIScrollView()
    private let welcomeCover = UIView()
    private let welcomeImage = UIImageView()
    private let welcomeMark = UILabel()
    private let welcomeEyebrow = UILabel()
    private let welcomeHeading = UILabel()
    private let welcomeSubtitle = UILabel()
    private let welcomeStart = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let homeEditor = UIView()
    private let homeEditorPreviewImage = UIImageView()
    private let homeEditorMark = UILabel()
    private let homeEditorEyebrow = UILabel()
    private let homeEditorHeading = UILabel()
    private let homeEditorSubtitle = UILabel()
    private let homeEditorStart = UILabel()
    private let homeSymbolField = UITextField()
    private let homeEyebrowField = UITextField()
    private let homeTitleField = UITextField()
    private let homeSubtitleField = UITextField()
    private let homeButtonField = UITextField()
    private let homePreset = UISegmentedControl(items: ["通用", "婚礼", "生日", "年会", "品牌"])
    private var homeSettings = HomePageSettings.load()
    private var welcomeBackground = HomePageBackgroundStore.load() ?? UIImage(named: "wedding-welcome-cover")
    private var draftWelcomeBackground: UIImage?
    private var draftUsesCustomBackground = HomePageBackgroundStore.load() != nil
    private var backgroundPickerActive = false
    private let printEditor = UIView()
    private let printEditorPreview = UIImageView()
    private let printEditorConfirm = UIButton(type: .system)
    private var renderingPrintDraft = false
    private var preparingMijiaShare = false
    private let printEditorBorder = UISegmentedControl(items: ["无边框", "白边", "奶油", "樱粉", "香槟", "酒红", "鼠尾草", "黑边"])
    private let templateStrip = UIStackView()
    private var templateButtons: [UIButton] = []
    private var printDraftStyle: PhotoStyle?
    private var printDraftImage: UIImage?
    private var printEditorRevision = 0
    private var panelWidth: NSLayoutConstraint!
    private var stageHeight: NSLayoutConstraint!
    private var style: PhotoStyle = {
        var style = PhotoStyle(printSize: .six)
        style.paper = .xiaomiSix
        style.mijiaPaperMode = .sixInch
        style.direction = .landscape
        return style
    }()
    private let renderQueue = DispatchQueue(label: "snapbooth.photo.render", qos: .userInitiated)
    private var renderRevision = 0
    private var rendering = false
    private var renderingLive = false
    private let accent = UIColor(red: 0.86, green: 0.28, blue: 0.12, alpha: 1)
    private var subscriptions = Set<AnyCancellable>()
    private var countdown: Task<Void, Never>?
    private var busy = false
    private var printable: UIImage?
    private var expectingCameraCapture = false
    private var pendingAutoSave = false
    
    init(camera: CameraService, printer: PrinterService) {
        self.camera = camera
        self.printer = printer
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
                view.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        view.tintColor = accent
        overrideUserInterfaceStyle = .light
        let title = UILabel()
        title.text = "SnapBooth."
        title.font = .systemFont(ofSize: 32, weight: .black)
        title.textColor = UIColor(white: 0.12, alpha: 1)
        status.numberOfLines = 0
        printerStatus.numberOfLines = 0
        live.videoPreviewLayer.videoGravity = .resizeAspectFill
        live.backgroundColor = .black
        live.layer.cornerRadius = 20
        live.clipsToBounds = true
        photo.contentMode = .scaleAspectFit
        photo.backgroundColor = .black
        photo.isHidden = true
        live.addSubview(photo)
        photo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: live.topAnchor),
            photo.bottomAnchor.constraint(equalTo: live.bottomAnchor),
            photo.leadingAnchor.constraint(equalTo: live.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: live.trailingAnchor)
        ])
        installCaptureLoadingOverlay()
        layout.selectedSegmentIndex = 0
        mode.selectedSegmentIndex = PrinterService.Mode.available.firstIndex(of: printer.mode) ?? 0
        [aspect, filter, frame, placement, printSize, rotation].forEach { $0.selectedSegmentIndex = 0 }
        direction.selectedSegmentIndex = PaperDirection.allCases.firstIndex(of: .landscape)!
        configure(paper, selectedPaper.rawValue) { }
        paper.showsMenuAsPrimaryAction = true
        paper.menu = UIMenu(children: PaperSize.allCases.map { value in
            UIAction(title: value.rawValue) { [weak self] _ in
                self?.selectedPaper = value
                self?.paper.setTitle(value.rawValue, for: .normal)
                self?.styleChanged()
            }
        })
        sizeInfo.font = .systemFont(ofSize: 12)
        sizeInfo.numberOfLines = 0
        printSize.selectedSegmentIndex = PhotoPrintSize.allCases.firstIndex(of: .six)!
        sizeInfo.text = "6英寸横向相纸 · 固定输出 1800×1200 JPEG"
        timer.selectedSegmentIndex = 1
        timer.backgroundColor = UIColor(red: 0.95, green: 0.92, blue: 0.87, alpha: 1)
        timer.setTitleTextAttributes([.foregroundColor: UIColor(white: 0.2, alpha: 1)], for: .normal)
        strength.value = 1
        strength.isContinuous = true
        strength.accessibilityLabel = "滤镜强度"
        for selector in [aspect, filter, frame, direction, placement, rotation] {
            selector.addAction(UIAction { [weak self] _ in self?.styleChanged() }, for: .valueChanged)
        }
        printSize.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let choice = PhotoPrintSize.allCases[self.printSize.selectedSegmentIndex]
            #if targetEnvironment(macCatalyst)
            self.selectedPaper = choice == .six ? .xiaomiSix : choice.defaultPaper
            #else
            self.selectedPaper = choice.defaultPaper
            #endif
            self.paper.setTitle(self.selectedPaper.rawValue, for: .normal)
            self.styleChanged()
        }, for: .valueChanged)
        strength.addAction(UIAction { [weak self] _ in self?.styleChanged() }, for: .valueChanged)
        layout.addAction(UIAction { [weak self] _ in self?.renderPhoto() }, for: .valueChanged)
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.printer.mode = PrinterService.Mode.available[self.mode.selectedSegmentIndex]
            self.updateButtons()
        }, for: .valueChanged)
        configure(cameraButton, "选择相机") { [weak self] in self?.camera.refreshCameras() }
        cameraButton.showsMenuAsPrimaryAction = true
        let refresh = UIButton(type: .system)
        configure(refresh, "刷新设备") { [weak self] in self?.camera.refreshCameras() }
        configure(recoverCameraPhoto, "读取相机最近照片") { [weak self] in self?.recoverLatestCameraPhoto() }
        recoverCameraPhoto.configuration?.image = UIImage(systemName: "arrow.down.circle")
        recoverCameraPhoto.configuration?.imagePadding = 7
        configure(shutter, "开始拍照") { [weak self] in self?.capture() }
        shutter.tag = 1
        shutter.configuration?.baseBackgroundColor = accent
        shutter.configuration?.baseForegroundColor = .white
        shutter.configuration?.background.backgroundColor = accent
        shutter.configuration?.image = UIImage(systemName: "camera.aperture")
        shutter.configuration?.imagePadding = 10
        configure(retake, "重新拍摄") { [weak self] in
            self?.pendingAutoSave = false
            self?.hideCaptureLoading()
            self?.camera.clearCapture()
        }
        configure(printButton, "打印这张照片") { [weak self] in
            self?.startPhotoPrint()
        }
        printButton.configuration?.image = UIImage(systemName: "printer")
        printButton.configuration?.imagePadding = 8
        saveStatus.font = .systemFont(ofSize: 12)
        saveStatus.textColor = .secondaryLabel
        saveStatus.numberOfLines = 0
        #if targetEnvironment(macCatalyst)
        saveStatus.text = "拍摄后自动保存到“图片/SnapBooth” · 包含滤镜与排版"
        #else
        saveStatus.text = "拍摄后自动保存到照片图库 · 包含滤镜与排版"
        #endif
        let choose = printerChoice
        #if targetEnvironment(macCatalyst)
        configure(choose, "重新检测米家 USB 打印机") { [weak self] in self?.printer.checkPrinter() }
        #else
        configure(choose, "选择 AirPrint 打印机") { [weak self] in self?.printer.choosePrinter() }
        #endif
        let export = UIButton(type: .system)
        configure(export, "导出最近的打印图片") { [weak self, weak export] in
            guard let self, let url = self.printer.lastMockPrintURL else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = export
            self.present(sheet, animated: true)
        }
        let subtitle = label("YOUR MOMENT, YOUR WAY", size: 10, weight: .semibold)
        subtitle.textColor = accent
        editorState.text = "实时预览 · 调整即生效"
        editorState.font = .systemFont(ofSize: 12)
        editorState.textColor = .secondaryLabel
        editorState.numberOfLines = 0
        let intensityTitle = label("滤镜强度", size: 12)
        let reset = UIButton(type: .system)
        configure(reset, "恢复原片风格") { [weak self] in
            guard let self else { return }
            self.aspect.selectedSegmentIndex = 0
            self.filter.selectedSegmentIndex = 0
            self.frame.selectedSegmentIndex = 0
            self.strength.value = 1
            self.styleChanged()
        }
        paperSettings.axis = .vertical
        paperSettings.spacing = 10
        paperSettings.addArrangedSubview(paper)
        paperSettings.addArrangedSubview(label("默认自动匹配。仅打印机使用不同规格相纸时修改；3寸默认50×76 mm，小米桌面3寸需选择86×102 mm。", size: 11))
        paperSettings.isHidden = true
        let advanced = UIButton(type: .system)
        configure(advanced, "打印设置 · 展开") { [weak self, weak advanced] in
            guard let self else { return }
            self.paperSettings.isHidden.toggle()
            advanced?.setTitle(self.paperSettings.isHidden ? "打印设置 · 展开" : "打印设置 · 收起", for: .normal)
        }
        let controls = UIStackView(arrangedSubviews: [
            subtitle, title,
            card("01  ·  拍摄设备", views: [
                status,
                cameraButton,
                label("iPad 主模式：佳能 CCAPI Wi-Fi 遥控会触发 R50 V 真快门与 AD-E1 热靴闪光；Type-C/UVC 仅作无闪光预览备用。", size: 11),
                refresh,
                recoverCameraPhoto
            ]),
            card("02  ·  照片风格", views: [editorState, label("画幅 · 居中裁切", size: 12), aspect, label("滤镜", size: 12), filter, intensityTitle, strength, reset]),
            card("03  ·  照片尺寸", views: photoSizeViews()),
            card("04  ·  自动保存与打印", views: printViews(saveStatus: saveStatus, advanced: advanced, choose: choose, export: export)),
            label("SNAPBOOTH STUDIO  /  0.5.1 · BUILD 26", size: 10)
        ])
        controls.axis = .vertical
        controls.spacing = 16
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        stage.backgroundColor = UIColor(white: 0.08, alpha: 1)
        stage.layer.cornerRadius = 28
        stage.clipsToBounds = true
        stageLabel.text = "●  LIVE STUDIO"
        stageLabel.textColor = .white
        stageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        var homeConfiguration = UIButton.Configuration.plain()
        homeConfiguration.title = "返回首页"
        homeConfiguration.image = UIImage(systemName: "house")
        homeConfiguration.imagePadding = 7
        homeConfiguration.baseForegroundColor = .white
        homeButton.configuration = homeConfiguration
        homeButton.addAction(UIAction { [weak self] _ in self?.showHomePage() }, for: .touchUpInside)
        let stageHeaderSpacer = UIView()
        let stageHeader = UIStackView(arrangedSubviews: [stageLabel, stageHeaderSpacer, homeButton])
        stageHeader.axis = .horizontal
        stageHeader.alignment = .center
        countdownLabel.font = .systemFont(ofSize: 100, weight: .black)
        countdownLabel.textAlignment = .center
        countdownLabel.textColor = .white
        countdownLabel.isUserInteractionEnabled = false
        actionButtons.addArrangedSubview(shutter)
        actionButtons.addArrangedSubview(retake)
        actionButtons.axis = .horizontal
        actionButtons.distribution = .fillEqually
        shooting.addArrangedSubview(timer)
        shooting.addArrangedSubview(toolbarSpacer)
        shooting.addArrangedSubview(actionButtons)
        shooting.axis = .horizontal
        shooting.alignment = .center
        shooting.spacing = 16
        let timerWidth = timer.widthAnchor.constraint(equalToConstant: 300)
        timerWidth.priority = .defaultHigh
        let actionWidth = actionButtons.widthAnchor.constraint(equalToConstant: 180)
        actionWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([timerWidth, actionWidth, shooting.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        let stageContent = UIStackView(arrangedSubviews: [stageHeader, live, shooting])
        stageContent.axis = .vertical
        stageContent.spacing = 16
        stageContent.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(stageContent)
        stage.addSubview(countdownLabel)
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(stage)
        root.addArrangedSubview(scroll)
        root.axis = .horizontal
        root.spacing = 24
        view.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        panelWidth = scroll.widthAnchor.constraint(equalToConstant: 370)
        stageHeight = stage.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.53)
        panelWidth.isActive = true
        NSLayoutConstraint.activate([
            stageContent.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            stageContent.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),
            stageContent.topAnchor.constraint(equalTo: stage.topAnchor, constant: 24),
            stageContent.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -24),
            countdownLabel.centerXAnchor.constraint(equalTo: live.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: live.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            controls.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            controls.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            controls.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        photo.setContentHuggingPriority(.defaultLow, for: .vertical)
        photo.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        photo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        live.videoPreviewLayer.session = camera.session
        camera.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.status.text = state.description
            self?.updateButtons()
        }.store(in: &subscriptions)
        camera.$cameras.receive(on: DispatchQueue.main).sink { [weak self] options in
            guard let self else { return }
            var items: [UIMenuElement] = options.map { option in
                UIAction(title: option.name) { [weak self] _ in
                    self?.camera.selectCamera(id: option.id)
                    self?.cameraButton.setTitle(option.name, for: .normal)
                }
            }
            #if !targetEnvironment(macCatalyst)
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "设置佳能 Wi-Fi 地址…", image: UIImage(systemName: "wifi")) { [weak self] _ in
                    self?.showCanonCCAPISetup()
                }
            ]))
            #endif
            self.cameraButton.menu = UIMenu(children: items)
        }.store(in: &subscriptions)
        camera.$selectedCameraID.receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self else { return }
            self.cameraButton.setTitle(self.camera.cameras.first(where: { $0.id == id })?.name ?? "选择相机", for: .normal)
        }.store(in: &subscriptions)
        camera.$capturedImage.receive(on: DispatchQueue.main).sink { [weak self] image in
            guard let self else { return }
            if image != nil, self.expectingCameraCapture {
                self.pendingAutoSave = true
                self.expectingCameraCapture = false
                self.showCaptureLoading("正在生成照片", detail: "正在应用画幅、滤镜与 6 英寸排版…")
            }
            self.renderPhoto()
            self.updateButtons()
        }.store(in: &subscriptions)
        camera.$latestFrame.receive(on: DispatchQueue.main).sink { [weak self] frame in
            guard let self, let frame, self.camera.capturedImage == nil else { return }
            self.renderLive(frame)
        }.store(in: &subscriptions)
        printer.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if self?.printer.mode == .mijiaShare && state == .printing {
                self?.printerStatus.text = "正在分享照片，请在分享面板选择米家"
            } else {
                self?.printerStatus.text = state == .ready && self?.printer.mode == .mock ? "模拟输出已就绪 · 无需打印机" : state.description
            }
            self?.updateButtons()
        }.store(in: &subscriptions)
        installWelcomeCover()
        updateButtons()
    }

    #if DEBUG && targetEnvironment(simulator)
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.arguments.contains("--mijia-share-smoke-test"),
              printer.state != .printing else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 1200), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
            ("SnapBooth · 分享测试 / 不打印" as NSString).draw(at: CGPoint(x: 120, y: 480), withAttributes: [
                .font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.white
            ])
        }
        assert(printer.mode == .mijiaShare)
        var testStyle = PhotoStyle()
        let plain = PrintLayoutRenderer.photoWithoutPaper(image: image, style: testStyle)
        testStyle.borderInset = 100
        testStyle.weddingTemplate = .redGold
        let noBorder = PrintLayoutRenderer.photoWithoutPaper(image: image, style: testStyle)
        assert(noBorder.size == CGSize(width: 1800, height: 1200))
        assert(plain.pngData() == noBorder.pngData(), "米家分享不能合成边框或模板")
        testStyle.quarterTurns = 1
        let rotated = PrintLayoutRenderer.photoWithoutPaper(image: image, style: testStyle)
        assert(rotated.size == CGSize(width: 1200, height: 1800))
        print("[MijiaShareSmokeTest] PASS: no borders/templates; photo rotation preserved")
        printer.print(image: noBorder, presenting: self)
    }
    #endif

    private func installCaptureLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.46)
        loadingOverlay.isHidden = true
        loadingOverlay.isUserInteractionEnabled = true

        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 22
        card.clipsToBounds = true

        loadingSpinner.color = .white
        loadingSpinner.hidesWhenStopped = false
        loadingTitle.font = .systemFont(ofSize: 18, weight: .bold)
        loadingTitle.textColor = .white
        loadingTitle.textAlignment = .center
        loadingDetail.font = .systemFont(ofSize: 12, weight: .medium)
        loadingDetail.textColor = UIColor.white.withAlphaComponent(0.68)
        loadingDetail.textAlignment = .center
        loadingDetail.numberOfLines = 2

        let content = UIStackView(arrangedSubviews: [loadingSpinner, loadingTitle, loadingDetail])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 10
        card.contentView.addSubview(content)
        loadingOverlay.addSubview(card)
        live.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: live.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: live.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: live.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: live.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 310),
            card.heightAnchor.constraint(equalToConstant: 156),
            content.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor)
        ])
    }

    private func showCaptureLoading(_ title: String, detail: String) {
        loadingTitle.text = title
        loadingDetail.text = detail
        loadingOverlay.accessibilityLabel = "\(title)，\(detail)"
        loadingSpinner.startAnimating()
        live.bringSubviewToFront(loadingOverlay)
        if loadingOverlay.isHidden {
            loadingOverlay.alpha = 0
            loadingOverlay.isHidden = false
            UIView.animate(withDuration: 0.18) { self.loadingOverlay.alpha = 1 }
        }
    }

    private func hideCaptureLoading() {
        guard !loadingOverlay.isHidden else { return }
        UIView.animate(withDuration: 0.18, animations: { self.loadingOverlay.alpha = 0 }) { _ in
            self.loadingSpinner.stopAnimating()
            self.loadingOverlay.isHidden = true
            self.loadingOverlay.alpha = 1
        }
    }

    private func installWelcomeCover() {
        welcomeCover.translatesAutoresizingMaskIntoConstraints = false
        welcomeCover.backgroundColor = UIColor(red: 0.30, green: 0.02, blue: 0.03, alpha: 1)
        welcomeCover.clipsToBounds = true

        welcomeImage.translatesAutoresizingMaskIntoConstraints = false
        welcomeImage.image = welcomeBackground
        welcomeImage.contentMode = .scaleAspectFill
        welcomeImage.accessibilityLabel = "首页活动背景"

        let veil = UIView()
        veil.translatesAutoresizingMaskIntoConstraints = false
        veil.backgroundColor = UIColor.black.withAlphaComponent(0.26)

        welcomeMark.font = .systemFont(ofSize: 82, weight: .light)
        welcomeMark.textColor = UIColor(red: 1.0, green: 0.86, blue: 0.57, alpha: 1)
        welcomeMark.textAlignment = .center

        welcomeEyebrow.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        welcomeEyebrow.textColor = UIColor.white.withAlphaComponent(0.92)
        welcomeEyebrow.textAlignment = .center

        welcomeHeading.font = .systemFont(ofSize: 52, weight: .bold)
        welcomeHeading.textColor = .white
        welcomeHeading.textAlignment = .center
        welcomeHeading.adjustsFontSizeToFitWidth = true
        welcomeHeading.minimumScaleFactor = 0.65

        welcomeSubtitle.font = .systemFont(ofSize: 20, weight: .medium)
        welcomeSubtitle.textColor = UIColor.white.withAlphaComponent(0.90)
        welcomeSubtitle.textAlignment = .center

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "camera.aperture")
        configuration.imagePadding = 12
        configuration.baseBackgroundColor = UIColor(red: 0.68, green: 0.04, blue: 0.06, alpha: 1)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 17, leading: 42, bottom: 17, trailing: 42)
        welcomeStart.configuration = configuration
        welcomeStart.titleLabel?.font = .systemFont(ofSize: 19, weight: .bold)
        welcomeStart.addAction(UIAction { [weak self] _ in self?.enterBooth() }, for: .touchUpInside)

        let edit = UIButton(type: .system)
        var editConfiguration = UIButton.Configuration.filled()
        editConfiguration.title = "编辑首页"
        editConfiguration.image = UIImage(systemName: "slider.horizontal.3")
        editConfiguration.imagePadding = 8
        editConfiguration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.36)
        editConfiguration.baseForegroundColor = .white
        editConfiguration.cornerStyle = .capsule
        editConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18)
        edit.configuration = editConfiguration
        edit.accessibilityLabel = "编辑首页"
        edit.addAction(UIAction { [weak self] _ in self?.showHomeEditor() }, for: .touchUpInside)

        let copy = UIStackView(arrangedSubviews: [welcomeMark, welcomeEyebrow, welcomeHeading, welcomeSubtitle, welcomeStart])
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.axis = .vertical
        copy.alignment = .center
        copy.spacing = 16
        copy.setCustomSpacing(4, after: welcomeMark)
        copy.setCustomSpacing(26, after: welcomeSubtitle)

        welcomeCover.addSubview(welcomeImage)
        welcomeCover.addSubview(veil)
        welcomeCover.addSubview(copy)
        welcomeCover.addSubview(edit)
        view.addSubview(welcomeCover)
        edit.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            welcomeCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            welcomeCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            welcomeCover.topAnchor.constraint(equalTo: view.topAnchor),
            welcomeCover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            welcomeImage.leadingAnchor.constraint(equalTo: welcomeCover.leadingAnchor),
            welcomeImage.trailingAnchor.constraint(equalTo: welcomeCover.trailingAnchor),
            welcomeImage.topAnchor.constraint(equalTo: welcomeCover.topAnchor),
            welcomeImage.bottomAnchor.constraint(equalTo: welcomeCover.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: welcomeCover.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: welcomeCover.trailingAnchor),
            veil.topAnchor.constraint(equalTo: welcomeCover.topAnchor),
            veil.bottomAnchor.constraint(equalTo: welcomeCover.bottomAnchor),
            copy.centerXAnchor.constraint(equalTo: welcomeCover.centerXAnchor),
            copy.centerYAnchor.constraint(equalTo: welcomeCover.centerYAnchor, constant: 20),
            copy.leadingAnchor.constraint(greaterThanOrEqualTo: welcomeCover.leadingAnchor, constant: 36),
            copy.trailingAnchor.constraint(lessThanOrEqualTo: welcomeCover.trailingAnchor, constant: -36),
            welcomeHeading.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            welcomeStart.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            edit.trailingAnchor.constraint(equalTo: welcomeCover.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            edit.topAnchor.constraint(equalTo: welcomeCover.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
        applyHomeSettings()
    }

    private func enterBooth() {
        camera.start()
        UIView.transition(with: view, duration: 0.55, options: [.transitionCrossDissolve, .curveEaseInOut]) {
            self.welcomeCover.alpha = 0
        } completion: { _ in
            self.welcomeCover.isHidden = true
        }
    }

    private func showHomePage() {
        countdown?.cancel()
        countdownLabel.text = nil
        busy = false
        pendingAutoSave = false
        expectingCameraCapture = false
        hideCaptureLoading()
        camera.clearCapture()
        camera.stop()
        welcomeCover.isHidden = false
        view.bringSubviewToFront(welcomeCover)
        welcomeCover.alpha = 0
        UIView.animate(withDuration: 0.35) { self.welcomeCover.alpha = 1 }
    }

    private func applyHomeSettings() {
        welcomeMark.text = homeSettings.symbol
        welcomeEyebrow.text = homeSettings.eyebrow
        welcomeHeading.text = homeSettings.title
        welcomeSubtitle.text = homeSettings.subtitle
        welcomeStart.configuration?.title = homeSettings.buttonTitle
        welcomeImage.image = welcomeBackground
    }

    private func showHomeEditor() {
        installHomeEditorIfNeeded()
        homeSymbolField.text = homeSettings.symbol
        homeEyebrowField.text = homeSettings.eyebrow
        homeTitleField.text = homeSettings.title
        homeSubtitleField.text = homeSettings.subtitle
        homeButtonField.text = homeSettings.buttonTitle
        homePreset.selectedSegmentIndex = homePresetIndex(for: homeSettings)
        draftWelcomeBackground = welcomeBackground
        draftUsesCustomBackground = HomePageBackgroundStore.load() != nil
        updateHomeEditorPreview()
        homeEditor.isHidden = false
        homeEditor.alpha = 0
        view.bringSubviewToFront(homeEditor)
        UIView.animate(withDuration: 0.25) { self.homeEditor.alpha = 1 }
    }

    private func closeHomeEditor() {
        view.endEditing(true)
        UIView.animate(withDuration: 0.2, animations: { self.homeEditor.alpha = 0 }) { _ in
            self.homeEditor.isHidden = true
            self.homeEditor.alpha = 1
        }
    }

    private func installHomeEditorIfNeeded() {
        guard homeEditor.superview == nil else { return }
        homeEditor.translatesAutoresizingMaskIntoConstraints = false
        homeEditor.backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)

        let cancel = UIButton(type: .system)
        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = "返回首页"
        cancelConfiguration.image = UIImage(systemName: "chevron.left")
        cancelConfiguration.imagePadding = 7
        cancelConfiguration.baseForegroundColor = UIColor(white: 0.16, alpha: 1)
        cancel.configuration = cancelConfiguration
        cancel.addAction(UIAction { [weak self] _ in self?.closeHomeEditor() }, for: .touchUpInside)

        let pageTitle = UILabel()
        pageTitle.text = "首页编辑"
        pageTitle.font = .systemFont(ofSize: 24, weight: .bold)
        pageTitle.textColor = UIColor(white: 0.12, alpha: 1)
        pageTitle.textAlignment = .center
        let pageDetail = UILabel()
        pageDetail.text = "适用于婚礼、生日、年会、品牌活动等不同场景"
        pageDetail.font = .systemFont(ofSize: 11, weight: .medium)
        pageDetail.textColor = .secondaryLabel
        pageDetail.textAlignment = .center
        let pageHeading = UIStackView(arrangedSubviews: [pageTitle, pageDetail])
        pageHeading.axis = .vertical
        pageHeading.spacing = 2

        let done = UIButton(type: .system)
        var doneConfiguration = UIButton.Configuration.filled()
        doneConfiguration.title = "保存首页"
        doneConfiguration.image = UIImage(systemName: "checkmark")
        doneConfiguration.imagePadding = 7
        doneConfiguration.baseBackgroundColor = accent
        doneConfiguration.baseForegroundColor = .white
        doneConfiguration.cornerStyle = .capsule
        done.configuration = doneConfiguration
        done.addAction(UIAction { [weak self] _ in self?.saveHomeEditor() }, for: .touchUpInside)

        let topSpacer = UIView()
        let topBar = UIStackView(arrangedSubviews: [cancel, topSpacer, pageHeading, done])
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 12

        let previewPanel = UIView()
        previewPanel.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.backgroundColor = UIColor(white: 0.06, alpha: 1)
        previewPanel.layer.cornerRadius = 24
        previewPanel.clipsToBounds = true
        homeEditorPreviewImage.translatesAutoresizingMaskIntoConstraints = false
        homeEditorPreviewImage.contentMode = .scaleAspectFill
        homeEditorPreviewImage.accessibilityLabel = "首页实时预览"
        let previewVeil = UIView()
        previewVeil.translatesAutoresizingMaskIntoConstraints = false
        previewVeil.backgroundColor = UIColor.black.withAlphaComponent(0.30)

        homeEditorMark.font = .systemFont(ofSize: 62, weight: .light)
        homeEditorMark.textColor = UIColor(red: 1.0, green: 0.86, blue: 0.57, alpha: 1)
        homeEditorMark.textAlignment = .center
        homeEditorEyebrow.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        homeEditorEyebrow.textColor = UIColor.white.withAlphaComponent(0.92)
        homeEditorEyebrow.textAlignment = .center
        homeEditorHeading.font = .systemFont(ofSize: 34, weight: .bold)
        homeEditorHeading.textColor = .white
        homeEditorHeading.textAlignment = .center
        homeEditorHeading.adjustsFontSizeToFitWidth = true
        homeEditorHeading.minimumScaleFactor = 0.55
        homeEditorSubtitle.font = .systemFont(ofSize: 15, weight: .medium)
        homeEditorSubtitle.textColor = UIColor.white.withAlphaComponent(0.90)
        homeEditorSubtitle.textAlignment = .center
        homeEditorStart.font = .systemFont(ofSize: 14, weight: .bold)
        homeEditorStart.textColor = .white
        homeEditorStart.textAlignment = .center
        homeEditorStart.backgroundColor = UIColor(red: 0.68, green: 0.04, blue: 0.06, alpha: 0.96)
        homeEditorStart.layer.cornerRadius = 20
        homeEditorStart.clipsToBounds = true
        let previewCopy = UIStackView(arrangedSubviews: [homeEditorMark, homeEditorEyebrow, homeEditorHeading, homeEditorSubtitle, homeEditorStart])
        previewCopy.translatesAutoresizingMaskIntoConstraints = false
        previewCopy.axis = .vertical
        previewCopy.alignment = .fill
        previewCopy.spacing = 12
        previewCopy.setCustomSpacing(3, after: homeEditorMark)
        previewCopy.setCustomSpacing(20, after: homeEditorSubtitle)
        previewPanel.addSubview(homeEditorPreviewImage)
        previewPanel.addSubview(previewVeil)
        previewPanel.addSubview(previewCopy)

        homePreset.selectedSegmentIndex = 0
        homePreset.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.applyHomePreset(self.homePreset.selectedSegmentIndex)
        }, for: .valueChanged)

        let chooseBackground = UIButton(type: .system)
        configure(chooseBackground, "选择背景") { [weak self] in self?.chooseHomeBackground() }
        chooseBackground.configuration?.image = UIImage(systemName: "photo")
        chooseBackground.configuration?.imagePadding = 8
        chooseBackground.configuration?.titleLineBreakMode = .byClipping
        chooseBackground.accessibilityLabel = "选择背景图片"
        let defaultBackground = UIButton(type: .system)
        configure(defaultBackground, "默认背景") { [weak self] in
            self?.draftWelcomeBackground = UIImage(named: "wedding-welcome-cover")
            self?.draftUsesCustomBackground = false
            self?.updateHomeEditorPreview()
        }
        defaultBackground.configuration?.titleLineBreakMode = .byClipping
        defaultBackground.accessibilityLabel = "恢复默认背景"
        let backgroundButtons = UIStackView(arrangedSubviews: [chooseBackground, defaultBackground])
        backgroundButtons.axis = .horizontal
        backgroundButtons.distribution = .fillEqually
        backgroundButtons.spacing = 10

        let form = UIStackView(arrangedSubviews: [
            sectionLabel("场景快捷预设"), homePreset,
            sectionLabel("首页背景"), backgroundButtons,
            homeField("主题标志", field: homeSymbolField, placeholder: "例如 ✦、囍、HAPPY"),
            homeField("顶部短句", field: homeEyebrowField, placeholder: "WELCOME TO YOUR MOMENT"),
            homeField("主标题", field: homeTitleField, placeholder: "欢迎来到 SnapBooth"),
            homeField("副标题", field: homeSubtitleField, placeholder: "定格此刻 · 留住回忆"),
            homeField("开始按钮", field: homeButtonField, placeholder: "开始拍摄")
        ])
        form.axis = .vertical
        form.spacing = 13
        form.isLayoutMarginsRelativeArrangement = true
        form.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 24, trailing: 20)
        form.backgroundColor = .white
        form.layer.cornerRadius = 22

        let formScroll = UIScrollView()
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formScroll.showsVerticalScrollIndicator = false
        formScroll.addSubview(form)
        form.translatesAutoresizingMaskIntoConstraints = false

        let editorBody = UIStackView(arrangedSubviews: [previewPanel, formScroll])
        editorBody.translatesAutoresizingMaskIntoConstraints = false
        editorBody.axis = .horizontal
        editorBody.spacing = 22
        homeEditor.addSubview(topBar)
        homeEditor.addSubview(editorBody)
        view.addSubview(homeEditor)

        NSLayoutConstraint.activate([
            homeEditor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeEditor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeEditor.topAnchor.constraint(equalTo: view.topAnchor),
            homeEditor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            topBar.trailingAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            topBar.topAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.topAnchor, constant: 10),
            topBar.heightAnchor.constraint(equalToConstant: 54),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            editorBody.leadingAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            editorBody.trailingAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            editorBody.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            editorBody.bottomAnchor.constraint(equalTo: homeEditor.safeAreaLayoutGuide.bottomAnchor, constant: -22),
            previewPanel.widthAnchor.constraint(greaterThanOrEqualTo: editorBody.widthAnchor, multiplier: 0.52),
            formScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            formScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            homeEditorPreviewImage.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor),
            homeEditorPreviewImage.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor),
            homeEditorPreviewImage.topAnchor.constraint(equalTo: previewPanel.topAnchor),
            homeEditorPreviewImage.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor),
            previewVeil.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor),
            previewVeil.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor),
            previewVeil.topAnchor.constraint(equalTo: previewPanel.topAnchor),
            previewVeil.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor),
            previewCopy.centerXAnchor.constraint(equalTo: previewPanel.centerXAnchor),
            previewCopy.centerYAnchor.constraint(equalTo: previewPanel.centerYAnchor),
            previewCopy.leadingAnchor.constraint(greaterThanOrEqualTo: previewPanel.leadingAnchor, constant: 28),
            previewCopy.trailingAnchor.constraint(lessThanOrEqualTo: previewPanel.trailingAnchor, constant: -28),
            homeEditorStart.heightAnchor.constraint(equalToConstant: 42),
            homeEditorStart.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            form.topAnchor.constraint(equalTo: formScroll.contentLayoutGuide.topAnchor),
            form.bottomAnchor.constraint(equalTo: formScroll.contentLayoutGuide.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: formScroll.contentLayoutGuide.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: formScroll.contentLayoutGuide.trailingAnchor),
            form.widthAnchor.constraint(equalTo: formScroll.frameLayoutGuide.widthAnchor)
        ])
        homeEditor.isHidden = true
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let value = label(text, size: 12, weight: .semibold)
        value.textColor = .secondaryLabel
        return value
    }

    private func homeField(_ title: String, field: UITextField, placeholder: String) -> UIStackView {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.clearButtonMode = .whileEditing
        field.font = .systemFont(ofSize: 15)
        field.addAction(UIAction { [weak self] _ in self?.updateHomeEditorPreview() }, for: .editingChanged)
        let heading = label(title, size: 12, weight: .semibold)
        let stack = UIStackView(arrangedSubviews: [heading, field])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func applyHomePreset(_ index: Int) {
        let preset: HomePageSettings
        switch index {
        case 1:
            preset = HomePageSettings(symbol: "囍", eyebrow: "WELCOME TO OUR WEDDING", title: "欢迎来到我们的婚礼", subtitle: "定格欢喜 · 留住此刻", buttonTitle: "开始拍摄")
        case 2:
            preset = HomePageSettings(symbol: "HAPPY", eyebrow: "MAKE A WISH", title: "生日快乐", subtitle: "记录笑容 · 收藏惊喜", buttonTitle: "拍张照片")
        case 3:
            preset = HomePageSettings(symbol: "2026", eyebrow: "CELEBRATE TOGETHER", title: "年度欢聚时刻", subtitle: "并肩同行 · 共赴新程", buttonTitle: "留下合影")
        case 4:
            preset = HomePageSettings(symbol: "✦", eyebrow: "CREATE · CONNECT · SHARE", title: "欢迎来到现场", subtitle: "发现灵感 · 记录精彩", buttonTitle: "开始体验")
        default:
            preset = .generic
        }
        homeSymbolField.text = preset.symbol
        homeEyebrowField.text = preset.eyebrow
        homeTitleField.text = preset.title
        homeSubtitleField.text = preset.subtitle
        homeButtonField.text = preset.buttonTitle
        updateHomeEditorPreview()
    }

    private func homePresetIndex(for settings: HomePageSettings) -> Int {
        switch settings.title {
        case "欢迎来到我们的婚礼": return 1
        case "生日快乐": return 2
        case "年度欢聚时刻": return 3
        case "欢迎来到现场": return 4
        default: return 0
        }
    }

    private func updateHomeEditorPreview() {
        homeEditorPreviewImage.image = draftWelcomeBackground
        homeEditorMark.text = homeSymbolField.text
        homeEditorEyebrow.text = homeEyebrowField.text
        homeEditorHeading.text = homeTitleField.text
        homeEditorSubtitle.text = homeSubtitleField.text
        homeEditorStart.text = homeButtonField.text
    }

    private func chooseHomeBackground() {
        backgroundPickerActive = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func saveHomeEditor() {
        let settings = HomePageSettings(
            symbol: homeSymbolField.text ?? "",
            eyebrow: homeEyebrowField.text ?? "",
            title: homeTitleField.text ?? "",
            subtitle: homeSubtitleField.text ?? "",
            buttonTitle: homeButtonField.text?.isEmpty == false ? homeButtonField.text! : "开始拍摄"
        )
        do {
            try HomePageBackgroundStore.save(draftUsesCustomBackground ? draftWelcomeBackground : nil)
            homeSettings = settings
            homeSettings.persist()
            welcomeBackground = draftWelcomeBackground
            applyHomeSettings()
            closeHomeEditor()
        } catch {
            let alert = UIAlertController(title: "背景保存失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }

    private func startPhotoPrint() {
        guard printer.mode == .mijiaShare else {
            showPrintEditor()
            return
        }
        guard let source = camera.capturedImage, !preparingMijiaShare,
              printer.state != .printing else { return }
        preparingMijiaShare = true
        let settings = style
        printerStatus.text = "正在准备照片，边框和模板请在米家中选择…"
        updateButtons()
        renderQueue.async { [weak self] in
            let image = PrintLayoutRenderer.photoWithoutPaper(image: source, style: settings)
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparingMijiaShare = false
                self.printer.print(image: image, presenting: self, sourceView: self.printButton)
                self.updateButtons()
            }
        }
    }

    private func showPrintEditor() {
        guard let base = printable, camera.capturedImage != nil, !rendering, printer.state != .printing else { return }
        installPrintEditorIfNeeded()
        updatePrintConfirmationButton()
        var draft = style
        draft.weddingTemplate = .none
        printDraftStyle = draft
        printDraftImage = base
        printEditorBorder.selectedSegmentIndex = draft.borderInset == 0 ? 0 : 1
        refreshTemplateButtons(baseImage: base, selected: .none)
        printEditorPreview.image = base
        printEditor.isHidden = false
        printEditor.alpha = 0
        view.bringSubviewToFront(printEditor)
        UIView.animate(withDuration: 0.28) { self.printEditor.alpha = 1 }
    }

    private func installPrintEditorIfNeeded() {
        guard printEditor.superview == nil else { return }
        printEditor.translatesAutoresizingMaskIntoConstraints = false
        printEditor.backgroundColor = UIColor(white: 0.035, alpha: 1)

        let back = UIButton(type: .system)
        var backConfig = UIButton.Configuration.plain()
        backConfig.title = "返回拍摄"
        backConfig.image = UIImage(systemName: "chevron.left")
        backConfig.imagePadding = 7
        backConfig.baseForegroundColor = .white
        back.configuration = backConfig
        back.addAction(UIAction { [weak self] _ in self?.closePrintEditor() }, for: .touchUpInside)

        let title = UILabel()
        title.text = "打印照片"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        let detail = UILabel()
        detail.text = "6 英寸横向 · 1800×1200 · 编辑完成后再确认打印"
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = UIColor.white.withAlphaComponent(0.62)
        detail.textAlignment = .center
        let titleStack = UIStackView(arrangedSubviews: [title, detail])
        titleStack.axis = .vertical
        titleStack.spacing = 3

        let topSpacer = UIView()
        let topBar = UIStackView(arrangedSubviews: [back, topSpacer, titleStack])
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 12

        let previewPanel = UIView()
        previewPanel.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.backgroundColor = .black
        previewPanel.layer.cornerRadius = 22
        previewPanel.layer.borderWidth = 1
        previewPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        previewPanel.clipsToBounds = true
        printEditorPreview.translatesAutoresizingMaskIntoConstraints = false
        printEditorPreview.contentMode = .scaleAspectFit
        printEditorPreview.backgroundColor = .black
        printEditorPreview.accessibilityLabel = "打印成片预览"
        previewPanel.addSubview(printEditorPreview)

        let templateTitle = UILabel()
        templateTitle.text = "活动模板"
        templateTitle.textColor = .white
        templateTitle.font = .systemFont(ofSize: 15, weight: .bold)
        let templateHint = UILabel()
        templateHint.text = "12 款原创主题 · 左右滑动选择 · 效果会合成到最终照片"
        templateHint.textColor = UIColor.white.withAlphaComponent(0.52)
        templateHint.font = .systemFont(ofSize: 10)
        let templateHeading = UIStackView(arrangedSubviews: [templateTitle, templateHint])
        templateHeading.axis = .vertical
        templateHeading.spacing = 2

        let templateScroll = UIScrollView()
        templateScroll.translatesAutoresizingMaskIntoConstraints = false
        templateScroll.showsHorizontalScrollIndicator = false
        templateScroll.alwaysBounceHorizontal = true
        templateScroll.contentInset = UIEdgeInsets(top: 0, left: 1, bottom: 0, right: 18)
        templateStrip.translatesAutoresizingMaskIntoConstraints = false
        templateStrip.axis = .horizontal
        templateStrip.spacing = 12
        templateScroll.addSubview(templateStrip)

        for (index, template) in WeddingTemplate.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.accessibilityLabel = "\(template.rawValue)模板"
            button.layer.cornerRadius = 14
            button.clipsToBounds = true
            button.backgroundColor = UIColor(white: 0.12, alpha: 1)
            var config = UIButton.Configuration.plain()
            config.title = template == .redGold ? "推荐 · \(template.rawValue)" : template.rawValue
            config.imagePlacement = .top
            config.imagePadding = 7
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 7)
            button.configuration = config
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }
                self?.selectPrintTemplate(button)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 164),
                button.heightAnchor.constraint(equalToConstant: 124)
            ])
            templateStrip.addArrangedSubview(button)
            templateButtons.append(button)
        }

        let borderTitle = UILabel()
        borderTitle.text = "相纸底色"
        borderTitle.textColor = .white
        borderTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        printEditorBorder.selectedSegmentIndex = 1
        printEditorBorder.backgroundColor = UIColor(white: 0.13, alpha: 1)
        printEditorBorder.selectedSegmentTintColor = UIColor(red: 0.72, green: 0.05, blue: 0.07, alpha: 1)
        printEditorBorder.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        printEditorBorder.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        printEditorBorder.addAction(UIAction { [weak self] _ in self?.updatePrintBorder() }, for: .valueChanged)

        let confirm = printEditorConfirm
        var confirmConfig = UIButton.Configuration.filled()
        confirmConfig.title = "确认打印"
        confirmConfig.subtitle = "检查构图后，将这张成片发送到米家 USB 打印机"
        confirmConfig.image = UIImage(systemName: "printer.fill")
        confirmConfig.imagePadding = 12
        confirmConfig.baseBackgroundColor = UIColor(red: 0.70, green: 0.035, blue: 0.055, alpha: 1)
        confirmConfig.baseForegroundColor = .white
        confirmConfig.cornerStyle = .large
        confirm.configuration = confirmConfig
        confirm.accessibilityLabel = "确认打印"
        confirm.addAction(UIAction { [weak self] _ in self?.confirmPrintDraft() }, for: .touchUpInside)
        updatePrintConfirmationButton()

        let controls = UIStackView(arrangedSubviews: [templateHeading, templateScroll, borderTitle, printEditorBorder, confirm])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.axis = .vertical
        controls.spacing = 9
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        controls.backgroundColor = UIColor(white: 0.075, alpha: 1)
        controls.layer.cornerRadius = 20

        printEditor.addSubview(topBar)
        printEditor.addSubview(previewPanel)
        printEditor.addSubview(controls)
        view.addSubview(printEditor)
        NSLayoutConstraint.activate([
            printEditor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            printEditor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            printEditor.topAnchor.constraint(equalTo: view.topAnchor),
            printEditor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            topBar.trailingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            topBar.topAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.topAnchor, constant: 10),
            topBar.heightAnchor.constraint(equalToConstant: 54),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            topSpacer.widthAnchor.constraint(equalTo: back.widthAnchor),
            previewPanel.leadingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            previewPanel.trailingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            previewPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            previewPanel.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -14),
            previewPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            printEditorPreview.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 18),
            printEditorPreview.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -18),
            printEditorPreview.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 18),
            printEditorPreview.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor, constant: -18),
            controls.leadingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            controls.trailingAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            controls.bottomAnchor.constraint(equalTo: printEditor.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            controls.heightAnchor.constraint(equalToConstant: 315),
            templateScroll.heightAnchor.constraint(equalToConstant: 124),
            templateStrip.leadingAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.leadingAnchor),
            templateStrip.trailingAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.trailingAnchor),
            templateStrip.topAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.topAnchor),
            templateStrip.bottomAnchor.constraint(equalTo: templateScroll.contentLayoutGuide.bottomAnchor),
            templateStrip.heightAnchor.constraint(equalTo: templateScroll.frameLayoutGuide.heightAnchor),
            printEditorBorder.heightAnchor.constraint(equalToConstant: 34),
            confirm.heightAnchor.constraint(equalToConstant: 52)
        ])
        printEditor.isHidden = true
    }

    private func refreshTemplateButtons(baseImage: UIImage, selected: WeddingTemplate) {
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 144, height: 82)).image { _ in
            baseImage.draw(in: CGRect(x: 0, y: 0, width: 144, height: 82))
        }
        for (index, button) in templateButtons.enumerated() {
            let template = WeddingTemplate.allCases[index]
            let image = PrintLayoutRenderer.applyingTemplate(template, to: thumbnail)
            let isSelected = template == selected
            if var configuration = button.configuration {
                configuration.image = image.withRenderingMode(.alwaysOriginal)
                configuration.title = isSelected
                    ? "✓  \(template.rawValue)"
                    : (template == .redGold ? "推荐 · \(template.rawValue)" : template.rawValue)
                configuration.baseForegroundColor = isSelected
                    ? UIColor(red: 1.0, green: 0.73, blue: 0.42, alpha: 1)
                    : .white
                button.configuration = configuration
            }
            button.layer.borderWidth = isSelected ? 3 : 1
            button.layer.borderColor = UIColor(red: 0.95, green: 0.60, blue: 0.28, alpha: 1).cgColor
            button.backgroundColor = UIColor(white: isSelected ? 0.16 : 0.11, alpha: 1)
            button.layer.shadowColor = UIColor(red: 0.95, green: 0.60, blue: 0.28, alpha: 1).cgColor
            button.layer.shadowOpacity = isSelected ? 0.32 : 0
            button.layer.shadowRadius = isSelected ? 8 : 0
            button.layer.shadowOffset = .zero
            button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        }
    }

    private func selectPrintTemplate(_ sender: UIButton) {
        guard WeddingTemplate.allCases.indices.contains(sender.tag), var draft = printDraftStyle else { return }
        draft.weddingTemplate = WeddingTemplate.allCases[sender.tag]
        printDraftStyle = draft
        if let base = printable { refreshTemplateButtons(baseImage: base, selected: draft.weddingTemplate) }
        renderPrintDraft()
    }

    private func updatePrintBorder() {
        guard var draft = printDraftStyle else { return }
        let choices: [(PhotoFrame, CGFloat)] = [
            (.white, 0), (.white, 54), (.cream, 54), (.pink, 54),
            (.champagne, 54), (.wine, 54), (.sage, 54), (.black, 54)
        ]
        let choice = choices[max(0, printEditorBorder.selectedSegmentIndex)]
        draft.frame = choice.0
        draft.borderInset = choice.1
        draft.placement = choice.1 == 0 ? .fill : .fit
        printDraftStyle = draft
        renderPrintDraft()
    }

    private func renderPrintDraft() {
        guard let source = camera.capturedImage, let draft = printDraftStyle else { return }
        renderingPrintDraft = true
        updatePrintConfirmationButton()
        printEditorRevision += 1
        let revision = printEditorRevision
        let selectedLayout = PhotoLayout.allCases[layout.selectedSegmentIndex]
        renderQueue.async { [weak self] in
            let result = PrintLayoutRenderer.render(image: source, layout: selectedLayout, style: draft)
            DispatchQueue.main.async {
                guard let self, self.printEditorRevision == revision, !self.printEditor.isHidden else { return }
                self.printDraftImage = result
                self.printEditorPreview.image = result
                self.renderingPrintDraft = false
                self.updatePrintConfirmationButton()
            }
        }
    }

    private func closePrintEditor() {
        printEditorRevision += 1
        renderingPrintDraft = false
        UIView.animate(withDuration: 0.22, animations: { self.printEditor.alpha = 0 }) { _ in
            self.printEditor.isHidden = true
            self.printEditor.alpha = 1
            self.printDraftStyle = nil
            self.printDraftImage = nil
        }
    }

    private func confirmPrintDraft() {
        guard !renderingPrintDraft, let image = printDraftImage, printer.state != .printing else { return }
        if printer.mode == .mijiaShare {
            printer.print(image: image, presenting: self, sourceView: printEditorConfirm)
            return
        }
        closePrintEditor()
        printerStatus.text = "正在发送编辑后的照片…"
        printer.print(image: image)
    }

    private func updatePrintConfirmationButton() {
        let sharing = printer.mode == .mijiaShare
        printEditorConfirm.configuration?.title = renderingPrintDraft
            ? "正在合成照片…" : (sharing ? "用米家打印" : "确认打印")
        switch printer.mode {
        case .mijiaShare:
            printEditorConfirm.configuration?.subtitle = "在分享面板选择“米家”，进入米家后确认 6 英寸相纸与打印"
        case .xiaomiUSB:
            printEditorConfirm.configuration?.subtitle = "检查构图后，将这张成片发送到米家 USB 打印机"
        case .airPrint:
            printEditorConfirm.configuration?.subtitle = "将成片发送到所选 AirPrint 打印机"
        case .mock:
            printEditorConfirm.configuration?.subtitle = "仅生成模拟输出，不消耗相纸"
        }
        printEditorConfirm.configuration?.image = UIImage(systemName: sharing ? "square.and.arrow.up" : "printer.fill")
        printEditorConfirm.accessibilityLabel = sharing ? "用米家打印" : "确认打印"
        printEditorConfirm.isEnabled = !renderingPrintDraft && printer.state != .printing
    }

    private func configure(_ button: UIButton, _ title: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(red: 0.95, green: 0.92, blue: 0.87, alpha: 1)
        configuration.baseForegroundColor = UIColor(white: 0.18, alpha: 1)
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        button.configuration = configuration
        button.configurationUpdateHandler = { button in
            guard var config = button.configuration else { return }
            if !button.isEnabled {
                config.background.backgroundColor = UIColor(white: 0.82, alpha: 1)
                config.baseForegroundColor = UIColor(white: 0.4, alpha: 1)
            } else {
                config.background.backgroundColor = config.baseBackgroundColor
                config.baseForegroundColor = button.tag == 1 ? .white : UIColor(white: 0.18, alpha: 1)
            }
            button.configuration = config
        }
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func printViews(
        saveStatus: UILabel,
        advanced: UIButton,
        choose: UIButton,
        export: UIButton
    ) -> [UIView] {
        #if targetEnvironment(macCatalyst)
        return [
            saveStatus,
            label("米家 USB 固定输出 6 英寸、300 DPI；请装入 6 英寸相纸及配套色带。", size: 11),
            mode,
            choose,
            printerStatus,
            printButton,
            export
        ]
        #else
        return [
            saveStatus,
            advanced,
            paperSettings,
            label("米家 App：点击“用米家打印”后在分享面板选择米家。边框、模板和相纸在米家中设置；不会自动出纸。", size: 11),
            mode,
            choose,
            printerStatus,
            printButton,
            export
        ]
        #endif
    }
    private func photoSizeViews() -> [UIView] {
        #if targetEnvironment(macCatalyst)
        return [
            sizeInfo,
            label("照片旋转", size: 12),
            rotation,
            placement,
            label("米家 USB 固定使用 6 英寸相纸（100×180 mm，成像区 100×148 mm）。", size: 11)
        ]
        #else
        return [
            printSize,
            sizeInfo,
            label("横竖方向", size: 12),
            direction,
            label("照片旋转", size: 12),
            rotation,
            placement,
            layout,
            label("1寸、2寸自动拼版并标出裁切边界；普通照片自动匹配相纸。", size: 11)
        ]
        #endif
    }
    private func renderPhoto() {
        renderRevision += 1
        let revision = renderRevision
        guard let source = camera.capturedImage else {
            printable = nil
            if camera.latestFrame == nil {
                photo.image = nil
                photo.isHidden = true
            }
            rendering = false
            stageLabel.text = "●  LIVE STUDIO"
            editorState.text = "实时预览 · 设置会保留到下一张"
            updateButtons()
            if let frame = camera.latestFrame { renderLive(frame) }
            return
        }
        rendering = true
        editorState.text = "正在生成照片…"
        updateButtons()
        let selectedLayout = PhotoLayout.allCases[layout.selectedSegmentIndex]
        let settings = style
        renderQueue.async { [weak self] in
            let result = PrintLayoutRenderer.render(image: source, layout: selectedLayout, style: settings)
            DispatchQueue.main.async {
                guard let self, self.renderRevision == revision else { return }
                self.printable = result
                self.photo.image = result
                self.photo.isHidden = false
                self.rendering = false
                self.stageLabel.text = "○  YOUR PRINT PREVIEW"
                self.editorState.text = "\(settings.aspect.rawValue) · \(settings.filter.rawValue) · \(settings.frame.rawValue)"
                self.updateButtons()
                self.hideCaptureLoading()
                if self.pendingAutoSave {
                    self.pendingAutoSave = false
                    self.savePhoto()
                }
            }
        }
    }
    private func updateButtons() {
        updatePrintConfirmationButton()
        printButton.setTitle(printer.mode == .mijiaShare ? "用米家打印" : "打印这张照片", for: .normal)
        printButton.configuration?.title = printer.mode == .mijiaShare ? "用米家打印" : "打印这张照片"
        mode.isEnabled = !preparingMijiaShare && printer.state != .printing
        #if targetEnvironment(macCatalyst)
        printerChoice.isHidden = printer.mode != .xiaomiUSB
        #else
        printerChoice.isHidden = printer.mode != .airPrint
        #endif
        shutter.isEnabled = camera.state.isReady && !busy && camera.capturedImage == nil
        shutter.isHidden = camera.capturedImage != nil
        retake.isHidden = camera.capturedImage == nil
        retake.isEnabled = camera.capturedImage != nil && !busy && !preparingMijiaShare
        printButton.isEnabled = !preparingMijiaShare && printer.state != .printing && (printer.mode == .mijiaShare
            ? camera.capturedImage != nil
            : printable != nil && !rendering && PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true)
        cameraButton.isEnabled = !busy
        recoverCameraPhoto.isEnabled = !busy && (
            camera.selectedCameraID == CanonRemoteBridge.cameraID ||
            camera.selectedCameraID == CanonCCAPIClient.cameraID
        )
        timer.isEnabled = !busy
    }
    private func renderLive(_ frame: UIImage) {
        guard !renderingLive, camera.capturedImage == nil else { return }
        renderingLive = true
        let revision = renderRevision
        let settings = style
        let selectedLayout = PhotoLayout.allCases[layout.selectedSegmentIndex]
        renderQueue.async { [weak self] in
            let result = PrintLayoutRenderer.render(image: frame, layout: selectedLayout, style: settings, previewScale: 0.4)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderingLive = false
                guard self.camera.capturedImage == nil, self.renderRevision == revision else { return }
                self.photo.image = result
                self.photo.isHidden = false
                self.editorState.text = "实时预览 · \(settings.aspect.rawValue) · \(settings.filter.rawValue)"
            }
        }
    }
    private func savePhoto() {
        guard let image = printable, !rendering, !saving,
              PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true else { return }
        saving = true
        saveStatus.text = "正在准备照片…"
        updateButtons()
        // Snapshot the finished image; later edits cannot change this save operation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = NSMutableData()
            guard let cg = image.cgImage,
                  let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
                DispatchQueue.main.async { self?.finishSave("照片编码失败，请重试") }
                return
            }
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                DispatchQueue.main.async { self?.finishSave("照片编码失败，请重试") }
                return
            }
            let jpeg = data as Data
            #if targetEnvironment(macCatalyst)
            do {
                let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let folder = pictures.appendingPathComponent("SnapBooth", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let filename = "SnapBooth-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).jpg"
                let url = folder.appendingPathComponent(filename)
                try jpeg.write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self?.finishSave("已自动保存：图片/SnapBooth/\(filename)")
                }
            } catch {
                DispatchQueue.main.async { self?.finishSave("自动保存失败：\(error.localizedDescription)") }
            }
            #else
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
                guard authorization == .authorized || authorization == .limited else {
                    DispatchQueue.main.async { self?.finishSave("未获保存权限，请在系统设置中允许 SnapBooth 添加照片") }
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: jpeg, options: nil)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        self?.finishSave(success ? "已保存到照片图库" : "保存失败：\(error?.localizedDescription ?? "请重试")")
                    }
                }
            }
            #endif
        }
    }
    private func finishSave(_ message: String) {
        saving = false
        saveStatus.text = message
        updateButtons()
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard backgroundPickerActive else { return }
        backgroundPickerActive = false
        guard let url = urls.first,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            let alert = UIAlertController(title: "无法读取背景", message: "请选择 JPEG、PNG 或 HEIF 图片。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        draftWelcomeBackground = image
        draftUsesCustomBackground = true
        updateHomeEditorPreview()
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        backgroundPickerActive = false
    }
    private func capture() {
        // UIAction can occasionally be delivered again while the hierarchy is
        // transitioning. Never allow a second countdown/capture to overlap the
        // current one or a photo that is already being edited.
        guard !busy, camera.capturedImage == nil else { return }
        busy = true
        updateButtons()
        countdown = Task { @MainActor [weak self] in
            guard let self else { return }
            let seconds = [0, 3, 5, 10][self.timer.selectedSegmentIndex]
            for value in (0..<seconds).reversed() {
                self.countdownLabel.text = "\(value + 1)"
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError {
                    self.countdownLabel.text = nil
                    return
                } catch {
                    self.countdownLabel.text = nil
                    return
                }
            }
            guard !Task.isCancelled,
                  self.busy,
                  self.camera.capturedImage == nil else {
                self.countdownLabel.text = nil
                return
            }
            self.countdown = nil
            self.countdownLabel.text = nil
            self.expectingCameraCapture = true
            self.showCaptureLoading("正在拍摄并读取照片", detail: "请稍候，正在从相机下载高画质照片…")
            self.camera.capture { [weak self] result in
                self?.busy = false
                self?.shutter.setTitle("开始拍照", for: .normal)
                if case .failure(let error) = result {
                    self?.expectingCameraCapture = false
                    self?.status.text = error.localizedDescription
                    self?.hideCaptureLoading()
                }
                self?.updateButtons()
            }
        }
    }

    private func showCanonCCAPISetup() {
        let alert = UIAlertController(
            title: "连接佳能 R50 V",
            message: "在相机的 Camera Control API 页面查看 URL。iPad 与相机需连接同一 Wi-Fi；支持佳能 HTTPS 与 Digest 用户认证。",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.placeholder = "例如 192.168.1.2:8080"
            field.text = self?.camera.canonCCAPIAddress
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { [weak self] field in
            field.placeholder = "CCAPI 用户名（可留空）"
            field.text = self?.camera.canonCCAPIUsername
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "CCAPI 密码（可留空）"
            field.isSecureTextEntry = true
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak alert] _ in
            guard let fields = alert?.textFields,
                  let address = fields.first?.text,
                  !address.isEmpty else { return }
            self?.camera.configureCanonCCAPI(
                address: address,
                username: fields.indices.contains(1) ? fields[1].text ?? "" : "",
                password: fields.indices.contains(2) ? fields[2].text ?? "" : ""
            )
        })
        present(alert, animated: true)
    }
    private func recoverLatestCameraPhoto() {
        guard !busy else { return }
        busy = true
        expectingCameraCapture = true
        showCaptureLoading("正在读取相机照片", detail: "请稍候，正在下载并处理高画质照片…")
        updateButtons()
        camera.recoverLatestRemotePhoto { [weak self] result in
            guard let self else { return }
            self.busy = false
            if case .failure(let error) = result {
                self.expectingCameraCapture = false
                self.status.text = error.localizedDescription
                self.hideCaptureLoading()
            }
            self.updateButtons()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let narrowToolbar = stage.bounds.width < 540
        shooting.axis = narrowToolbar ? .vertical : .horizontal
        toolbarSpacer.isHidden = narrowToolbar
        let compact = view.bounds.width < 850
        if (root.axis == .vertical) != compact {
            panelWidth.isActive = false
            stageHeight.isActive = false
            root.axis = compact ? .vertical : .horizontal
            if compact { stageHeight.isActive = true } else { panelWidth.isActive = true }
        }
    }
    private func styleChanged() {
        style = PhotoStyle(aspect: PhotoAspect.allCases[aspect.selectedSegmentIndex], filter: PhotoFilter.allCases[filter.selectedSegmentIndex], frame: PhotoFrame.allCases[frame.selectedSegmentIndex], intensity: strength.value)
        #if targetEnvironment(macCatalyst)
        style.mijiaPaperMode = .sixInch
        selectedPaper = .xiaomiSix
        style.printSize = .six
        #else
        style.printSize = PhotoPrintSize.allCases[printSize.selectedSegmentIndex]
        #endif
        style.paper = selectedPaper
        style.direction = PaperDirection.allCases[direction.selectedSegmentIndex]
        style.placement = PhotoPlacement.allCases[placement.selectedSegmentIndex]
        style.quarterTurns = rotation.selectedSegmentIndex
        let fixed = style.printSize.isID
        aspect.isEnabled = !fixed
        layout.isEnabled = !fixed
        placement.isEnabled = !fixed
        #if targetEnvironment(macCatalyst)
        sizeInfo.text = "6英寸横向相纸 · 1800×1200 JPEG · media 5012/2010"
        sizeInfo.textColor = .secondaryLabel
        #else
        if let cells = PrintLayoutRenderer.standardCells(style: style) {
            sizeInfo.text = cells.isEmpty ? "所选相纸放不下这张标准照片，请换大相纸或旋转照片。不会自动缩小，已禁用打印。" : "\(style.printSize.detail) · 每纸 \(cells.count) 张 · 2 mm 间距"
            sizeInfo.textColor = cells.isEmpty ? .systemRed : .secondaryLabel
        } else {
            sizeInfo.text = "\(style.printSize.rawValue)照片 · \(selectedPaper.rawValue)"
            sizeInfo.textColor = .secondaryLabel
        }
        #endif
        renderPhoto()
    }
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }
    private func switchRow(_ text: String, control: UISwitch) -> UIView {
        let row = UIStackView(arrangedSubviews: [label(text, size: 12, weight: .semibold), control])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        return row
    }
    private func card(_ title: String, views: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: [label(title, size: 13, weight: .bold)] + views)
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 18, bottom: 20, trailing: 18)
        stack.backgroundColor = .white
        stack.layer.cornerRadius = 20
        return stack
    }
}
