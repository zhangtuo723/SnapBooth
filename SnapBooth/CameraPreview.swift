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
        view.videoPreviewLayer.videoGravity = .resizeAspect
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
    private let liveDecoration = LiveDecorationView()
    private var decorationRevision = -1
    private var decorationCanvas = CGSize.zero
    private let status = UILabel()
    private let printerStatus = UILabel()
    private let cameraButton = UIButton(type: .system)
    private let recoverCameraPhoto = UIButton(type: .system)
    private let shutter = UIButton(type: .system)
    private let retake = UIButton(type: .system)
    private let printButton = UIButton(type: .system)
    private let saveStatus = UILabel()
    private let saveCurrent = UIButton(type: .system)
    private var saving = false
    private var savedRevision: Int?
    private var savingRevision = 0
    private let printerChoice = UIButton(type: .system)
    private let layout = UISegmentedControl(items: PhotoLayout.allCases.map(\.rawValue))
    private let mode = UISegmentedControl(items: PrinterService.Mode.available.map(\.rawValue))
    private let filter = UISegmentedControl(items: PhotoFilter.allCases.map(\.rawValue))
    private let frame = UISegmentedControl(items: PhotoFrame.allCases.map(\.rawValue))
    private let strength = UISlider()
    private let intensityControls = UIStackView()
    private let filterChoice = UIButton(type: .system)
    private let moreAdjustments = UIStackView()
    private let flexibleFormat = UIStackView()
    private let exportButton = UIButton(type: .system)
    private let deliveryHint = UILabel()
    private let printingHelp = UILabel()
    private let printingDetail = UILabel()
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
    private var toolbarHeight: NSLayoutConstraint!
    private var actionWidth: NSLayoutConstraint!
    private let actionButtons = UIStackView()
    private let toolbarSpacer = UIView()
    private let countdownLabel = CountdownBadgeView()
    private let loadingOverlay = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let loadingTitle = UILabel()
    private let loadingDetail = UILabel()
    private let editorState = UILabel()
    private let root = UIStackView()
    private let scroll = UIScrollView()
    private let inspector = UIStackView()
    private let identity = UIStackView()
    private var savePanel: UIView!
    private let inspectorTabs = UISegmentedControl(items: ["照片", "相机", "打印"])
    private var inspectorPages: [UIView] = []
    private let previewHint = UILabel()
    private let previewPrompt = UIStackView()
    private let welcomeCover = UIView()
    private let welcomeImage = UIImageView()
    private let welcomeVeil = UIView()
    private let welcomeMark = UILabel()
    private let welcomeEyebrow = UILabel()
    private let welcomeHeading = UILabel()
    private let welcomeSubtitle = UILabel()
    private let welcomeStart = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let settingsToggle = UIButton(type: .system)
    private var settingsExpanded = true
    private let homeEditor = UIView()
    private let homeEditorPreviewImage = UIImageView()
    private let homeEditorVeil = UIView()
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
    private let selectedTemplateLabel = UILabel()
    private var templateSelection: TemplateSelectionController?
    private var panelWidth: NSLayoutConstraint!
    private var stageHeight: NSLayoutConstraint!
    private var style: PhotoStyle = {
        var style = PhotoStyle(printSize: .six)
        style.paper = .xiaomiSix
        style.mijiaPaperMode = .sixInch
        style.direction = .landscape
        style.weddingTemplate = .invitationIllustration
        return style
    }()
    private let renderQueue = DispatchQueue(label: "snapbooth.photo.render", qos: .userInitiated)
    private var renderRevision = 0
    private var rendering = false
    private var renderingLive = false
    private let accent = BoothTheme.accent
    private var subscriptions = Set<AnyCancellable>()
    private var countdown: Task<Void, Never>?
    private var busy = false
    private var printable: UIImage?
    private var expectingCameraCapture = false
    private var pendingAutoSave = false
    #if DEBUG && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
    private var didShowPrinterUSBDiagnostics = false
    #endif
    
    init(camera: CameraService, printer: PrinterService) {
        self.camera = camera
        self.printer = printer
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BoothTheme.canvas
        view.tintColor = accent
        overrideUserInterfaceStyle = .light
        let title = UILabel()
        title.text = "SnapBooth"
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = BoothTheme.ink
        [status, printerStatus].forEach {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = BoothTheme.secondary
        }
        status.numberOfLines = 0
        printerStatus.numberOfLines = 0
        live.videoPreviewLayer.videoGravity = .resizeAspect
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
        photo.addSubview(liveDecoration)
        liveDecoration.translatesAutoresizingMaskIntoConstraints = false
        liveDecoration.isUserInteractionEnabled = false
        liveDecoration.isHidden = true
        NSLayoutConstraint.activate([
            liveDecoration.leadingAnchor.constraint(equalTo: photo.leadingAnchor),
            liveDecoration.trailingAnchor.constraint(equalTo: photo.trailingAnchor),
            liveDecoration.topAnchor.constraint(equalTo: photo.topAnchor),
            liveDecoration.bottomAnchor.constraint(equalTo: photo.bottomAnchor)
        ])
        installCaptureLoadingOverlay()
        layout.selectedSegmentIndex = 0
        mode.selectedSegmentIndex = PrinterService.Mode.available.firstIndex(of: printer.mode) ?? 0
        [filter, frame, placement, printSize, rotation].forEach { $0.selectedSegmentIndex = 0 }
        direction.selectedSegmentIndex = PaperDirection.allCases.firstIndex(of: .landscape)!
        configure(paper, selectedPaper.rawValue) { }
        paper.showsMenuAsPrimaryAction = true
        paper.menu = UIMenu(children: PaperSize.allCases.map { value in
            UIAction(title: value.rawValue) { [weak self] _ in
                self?.selectedPaper = value
                self?.paper.setTitle(value.rawValue, for: .normal)
                self?.paper.configuration?.title = value.rawValue
                self?.styleChanged()
            }
        })
        sizeInfo.font = .preferredFont(forTextStyle: .subheadline)
        sizeInfo.textColor = BoothTheme.secondary
        sizeInfo.numberOfLines = 0
        printSize.selectedSegmentIndex = PhotoPrintSize.allCases.firstIndex(of: .six)!
        sizeInfo.text = "6 英寸 · 横向照片"
        timer.selectedSegmentIndex = 1
        timer.accessibilityLabel = "拍摄倒计时"
        strength.value = 1
        strength.isContinuous = true
        strength.accessibilityLabel = "滤镜强度"
        for selector in [filter, frame, direction, placement, rotation] {
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
            self.paper.configuration?.title = self.selectedPaper.rawValue
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
        configure(refresh, "重新查找相机") { [weak self] in self?.camera.refreshCameras() }
        refresh.configuration?.image = UIImage(systemName: "arrow.clockwise")
        configure(recoverCameraPhoto, "取回最近一张") { [weak self] in self?.recoverLatestCameraPhoto() }
        recoverCameraPhoto.configuration?.image = UIImage(systemName: "arrow.down.circle")
        recoverCameraPhoto.configuration?.imagePadding = 7
        configure(shutter, "拍照") { [weak self] in self?.capture() }
        BoothTheme.styleButton(shutter, title: "拍照", symbol: "camera", role: .primary)
        configure(retake, "重拍") { [weak self] in
            self?.pendingAutoSave = false
            self?.hideCaptureLoading()
            self?.camera.clearCapture()
        }
        configure(printButton, "去米家打印") { [weak self] in
            self?.startPhotoPrint()
        }
        BoothTheme.styleButton(printButton, title: "去米家打印", symbol: "printer", role: .primary)
        saveStatus.font = .preferredFont(forTextStyle: .subheadline)
        saveStatus.textColor = BoothTheme.secondary
        saveStatus.numberOfLines = 0
        configure(saveCurrent, "保存当前成片") { [weak self] in self?.savePhoto() }
        saveCurrent.configuration?.image = UIImage(systemName: "square.and.arrow.down")
        #if targetEnvironment(macCatalyst)
        saveStatus.text = "拍摄后自动保存到“图片 / SnapBooth”。"
        #else
        saveStatus.text = "拍摄后自动保存到系统相册。"
        #endif
        let choose = printerChoice
        #if targetEnvironment(macCatalyst)
        configure(choose, "重新检测米家 USB 打印机") { [weak self] in self?.printer.checkPrinter() }
        #else
        configure(choose, "选择 AirPrint 打印机") { [weak self] in self?.printer.choosePrinter() }
        #endif
        let export = exportButton
        configure(export, "分享最近保存的照片") { [weak self, weak export] in
            guard let self, let url = self.printer.lastMockPrintURL else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = export
            self.present(sheet, animated: true)
        }
        let subtitle = label("PHOTO STUDIO", size: 11, weight: .semibold)
        subtitle.textColor = accent
        editorState.text = "调整会同步到成片。"
        editorState.font = .preferredFont(forTextStyle: .subheadline)
        editorState.textColor = BoothTheme.secondary
        editorState.numberOfLines = 0
        let intensityTitle = label("滤镜强度", size: 13)
        intensityControls.axis = .vertical
        intensityControls.spacing = 8
        intensityControls.addArrangedSubview(intensityTitle)
        intensityControls.addArrangedSubview(strength)
        intensityControls.isHidden = true
        configure(filterChoice, "原片") { }
        filterChoice.showsMenuAsPrimaryAction = true
        updateFilterMenu()
        let reset = UIButton(type: .system)
        configure(reset, "重置照片调整") { [weak self] in
            guard let self else { return }
            self.filter.selectedSegmentIndex = 0
            self.strength.value = 1
            self.styleChanged()
        }
        BoothTheme.styleButton(reset, title: "重置照片调整", symbol: "arrow.counterclockwise", role: .quiet)
        paperSettings.axis = .vertical
        paperSettings.spacing = 10
        paperSettings.addArrangedSubview(paper)
        paperSettings.addArrangedSubview(label("仅在相纸规格不同时修改。米家打印时，请选择与成片匹配的相纸。", size: 13))
        paperSettings.isHidden = true
        let advanced = UIButton(type: .system)
        configure(advanced, "相纸与设备检测") { [weak self, weak advanced] in
            guard let self else { return }
            self.paperSettings.isHidden.toggle()
            advanced?.configuration?.image = UIImage(systemName: self.paperSettings.isHidden ? "chevron.down" : "chevron.up")
        }
        advanced.configuration?.image = UIImage(systemName: "chevron.down")
        moreAdjustments.axis = .vertical
        moreAdjustments.spacing = 12
        photoSizeViews().forEach { moreAdjustments.addArrangedSubview($0) }
        moreAdjustments.isHidden = true
        let more = UIButton(type: .system)
        configure(more, "尺寸与构图") { [weak self, weak more] in
            guard let self else { return }
            self.moreAdjustments.isHidden.toggle()
            more?.configuration?.image = UIImage(systemName: self.moreAdjustments.isHidden ? "chevron.down" : "chevron.up")
        }
        more.configuration?.image = UIImage(systemName: "chevron.down")
        let photoPage = UIStackView(arrangedSubviews: [
            makeCaptureTemplateCard(),
            card("照片风格", views: [editorState, filterChoice, intensityControls, reset]),
            card("更多调整", views: [sizeInfo, more, moreAdjustments])
        ])
        photoPage.axis = .vertical
        photoPage.spacing = 16
        #if targetEnvironment(macCatalyst)
        let connectionHint = "连接 USB 相机，或选择 Mac 摄像头开始拍摄。"
        #else
        let connectionHint = "佳能相机可通过 Type-C 直连或 Wi-Fi 遥控拍摄，也可使用设备摄像头。"
        #endif
        let devicePage = card("连接相机", views: [cameraButton, status,
            label(connectionHint, size: 13), refresh, recoverCameraPhoto])
        let outputPage = card("打印方式", views: printViews(saveStatus: saveStatus,
            advanced: advanced, choose: choose, export: export))
        inspectorPages = [photoPage, devicePage, outputPage]
        inspectorTabs.selectedSegmentIndex = 0
        inspectorTabs.accessibilityLabel = "工作台设置分类"
        inspectorTabs.addAction(UIAction { [weak self] _ in self?.selectInspectorPage() }, for: .valueChanged)
        let controls = UIStackView(arrangedSubviews: inspectorPages)
        selectInspectorPage()
        identity.addArrangedSubview(subtitle)
        identity.addArrangedSubview(title)
        identity.axis = .vertical
        identity.spacing = 4
        inspector.axis = .vertical
        inspector.spacing = 16
        inspector.addArrangedSubview(identity)
        inspector.addArrangedSubview(inspectorTabs)
        inspector.addArrangedSubview(scroll)
        deliveryHint.font = .preferredFont(forTextStyle: .subheadline)
        deliveryHint.textColor = BoothTheme.secondary
        deliveryHint.numberOfLines = 0
        let delivery = card("拍摄与保存", views: [saveStatus, saveCurrent, deliveryHint])
        savePanel = delivery
        inspector.addArrangedSubview(delivery)
        [filter, frame, direction, placement, printSize, rotation, timer, mode, inspectorTabs].forEach {
            BoothTheme.styleSegments($0)
        }
        controls.axis = .vertical
        controls.spacing = 16
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        stage.backgroundColor = BoothTheme.stage
        stage.layer.cornerRadius = 24
        stage.clipsToBounds = true
        stageLabel.text = "准备拍摄"
        stageLabel.textColor = .white
        stageLabel.font = .preferredFont(forTextStyle: .headline)
        var homeConfiguration = UIButton.Configuration.plain()
        homeConfiguration.title = "返回首页"
        homeConfiguration.image = UIImage(systemName: "house")
        homeConfiguration.imagePadding = 7
        homeConfiguration.baseForegroundColor = .white
        homeConfiguration.titleLineBreakMode = .byClipping
        homeButton.configuration = homeConfiguration
        homeButton.accessibilityLabel = "返回首页"
        homeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        homeButton.addAction(UIAction { [weak self] _ in self?.showHomePage() }, for: .touchUpInside)
        var settingsConfiguration = UIButton.Configuration.plain()
        settingsConfiguration.title = "收起设置"
        settingsConfiguration.image = UIImage(systemName: "sidebar.right")
        settingsConfiguration.imagePadding = 7
        settingsConfiguration.baseForegroundColor = .white
        settingsConfiguration.titleLineBreakMode = .byClipping
        settingsConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        settingsToggle.configuration = settingsConfiguration
        settingsToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsToggle.accessibilityIdentifier = "workspace-settings-toggle"
        settingsToggle.accessibilityValue = "已展开"
        settingsToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setSettingsExpanded(!self.settingsExpanded)
        }, for: .touchUpInside)
        let stageHeaderSpacer = UIView()
        stageHeaderSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stageHeaderSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stageHeader = UIStackView(arrangedSubviews: [stageLabel, stageHeaderSpacer, homeButton, settingsToggle])
        stageHeader.axis = .horizontal
        stageHeader.alignment = .center
        stageHeader.spacing = 8
        let headerHeight = stageHeader.heightAnchor.constraint(equalToConstant: 44)
        headerHeight.priority = UILayoutPriority(749)
        headerHeight.isActive = true
        actionButtons.addArrangedSubview(shutter)
        actionButtons.addArrangedSubview(retake)
        actionButtons.addArrangedSubview(printButton)
        actionButtons.axis = .horizontal
        actionButtons.spacing = 12
        actionButtons.distribution = .fillEqually
        shooting.addArrangedSubview(timer)
        shooting.addArrangedSubview(toolbarSpacer)
        shooting.addArrangedSubview(actionButtons)
        shooting.axis = .horizontal
        shooting.alignment = .center
        shooting.spacing = 16
        let timerWidth = timer.widthAnchor.constraint(equalToConstant: 220)
        timerWidth.priority = .defaultHigh
        actionWidth = actionButtons.widthAnchor.constraint(equalToConstant: 180)
        actionWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([timerWidth, actionWidth, shooting.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        toolbarHeight = shooting.heightAnchor.constraint(equalToConstant: 44)
        toolbarHeight.priority = UILayoutPriority(749)
        toolbarHeight.isActive = true
        let minimumPreview = live.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        minimumPreview.priority = .defaultHigh
        minimumPreview.isActive = true
        let stageContent = UIStackView(arrangedSubviews: [stageHeader, live, shooting])
        stageContent.axis = .vertical
        stageContent.spacing = 16
        stageContent.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(stageContent)
        previewHint.text = "准备好，留下这一刻"
        previewHint.numberOfLines = 0
        previewHint.textAlignment = .center
        previewHint.font = .systemFont(ofSize: 18, weight: .medium)
        previewHint.textColor = UIColor.white.withAlphaComponent(0.65)
        previewHint.isUserInteractionEnabled = false
        let connectCamera = UIButton(type: .system)
        configure(connectCamera, "连接相机") { [weak self] in
            self?.setSettingsExpanded(true)
            self?.inspectorTabs.selectedSegmentIndex = 1
            self?.selectInspectorPage()
        }
        connectCamera.configuration?.image = UIImage(systemName: "camera.badge.ellipsis")
        previewPrompt.axis = .vertical
        previewPrompt.alignment = .center
        previewPrompt.spacing = 20
        previewPrompt.addArrangedSubview(previewHint)
        previewPrompt.addArrangedSubview(connectCamera)
        live.addSubview(previewPrompt)
        previewPrompt.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewPrompt.centerXAnchor.constraint(equalTo: live.centerXAnchor),
            previewPrompt.centerYAnchor.constraint(equalTo: live.centerYAnchor),
            previewPrompt.leadingAnchor.constraint(greaterThanOrEqualTo: live.leadingAnchor, constant: 16),
            previewPrompt.trailingAnchor.constraint(lessThanOrEqualTo: live.trailingAnchor, constant: -16)
        ])
        stage.addSubview(countdownLabel)
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        let countdownSize = countdownLabel.widthAnchor.constraint(equalTo: live.heightAnchor, multiplier: 0.46)
        countdownSize.priority = .defaultHigh
        countdownSize.isActive = true
        root.addArrangedSubview(stage)
        root.addArrangedSubview(inspector)
        root.axis = .horizontal
        root.spacing = 20
        view.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        panelWidth = inspector.widthAnchor.constraint(equalToConstant: 390)
        stageHeight = stage.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.52)
        panelWidth.isActive = true
        NSLayoutConstraint.activate([
            stageContent.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            stageContent.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),
            stageContent.topAnchor.constraint(equalTo: stage.topAnchor, constant: 24),
            stageContent.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -24),
            countdownLabel.centerXAnchor.constraint(equalTo: live.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: live.centerYAnchor),
            countdownLabel.heightAnchor.constraint(equalTo: countdownLabel.widthAnchor),
            countdownLabel.widthAnchor.constraint(lessThanOrEqualTo: live.widthAnchor, multiplier: 0.65),
            countdownLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
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
            if let self, self.busy, self.expectingCameraCapture,
               self.camera.selectedCameraID == CanonUSBPTPClient.cameraID,
               case .unavailable(let message) = state {
                self.loadingTitle.text = message
                self.loadingDetail.text = "照片读取完成后会自动显示，请勿重复拍摄"
            }
            self?.updateButtons()
        }.store(in: &subscriptions)
        camera.$cameras.receive(on: DispatchQueue.main).sink { [weak self] options in
            guard let self else { return }
            var items: [UIMenuElement] = options.map { option in
                UIAction(title: option.name) { [weak self] _ in
                    self?.camera.selectCamera(id: option.id)
                    self?.cameraButton.setTitle(option.name, for: .normal)
                    self?.cameraButton.configuration?.title = option.name
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
            self.cameraButton.configuration?.title = self.camera.cameras.first(where: { $0.id == id })?.name ?? "选择相机"
        }.store(in: &subscriptions)
        camera.$capturedImage.receive(on: DispatchQueue.main).sink { [weak self] image in
            guard let self else { return }
            if image != nil, self.expectingCameraCapture {
                self.pendingAutoSave = true
                self.expectingCameraCapture = false
                self.showCaptureLoading("正在生成照片", detail: "正在应用滤镜与模板…")
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
                self?.printerStatus.text = state == .ready && self?.printer.mode == .mock ? "照片将保存到 App 文件。" : state.description
            }
            self?.updateButtons()
        }.store(in: &subscriptions)
        installWelcomeCover()
        styleChanged()
    }

    #if DEBUG && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Device smoke testing opens the same read-only page as the Output button.
        guard !didShowPrinterUSBDiagnostics,
              ProcessInfo.processInfo.arguments.contains("--printer-usb-diagnostics") else { return }
        didShowPrinterUSBDiagnostics = true
        showPrinterUSBDiagnostics()
    }
    #endif

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

        let veil = welcomeVeil
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
        BoothTheme.styleButton(welcomeStart, title: homeSettings.buttonTitle, symbol: "arrow.right", role: .primary)
        welcomeStart.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 36, bottom: 18, trailing: 36)
        welcomeStart.addAction(UIAction { [weak self] _ in self?.showTemplateSelection() }, for: .touchUpInside)

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
        let studioWelcome = HomePageBackgroundStore.load() == nil
        welcomeImage.isHidden = studioWelcome
        welcomeVeil.isHidden = studioWelcome
        welcomeCover.backgroundColor = studioWelcome ? BoothTheme.canvas : BoothTheme.stage
        welcomeHeading.textColor = studioWelcome ? BoothTheme.ink : .white
        welcomeEyebrow.textColor = studioWelcome ? BoothTheme.accent : .white.withAlphaComponent(0.92)
        welcomeSubtitle.textColor = studioWelcome ? BoothTheme.secondary : .white.withAlphaComponent(0.9)
        welcomeMark.textColor = studioWelcome ? BoothTheme.accent : UIColor(red: 1.0, green: 0.86, blue: 0.57, alpha: 1)
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
        homeEditor.backgroundColor = BoothTheme.canvas

        let cancel = UIButton(type: .system)
        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = "返回首页"
        cancelConfiguration.image = UIImage(systemName: "chevron.left")
        cancelConfiguration.imagePadding = 7
        cancelConfiguration.baseForegroundColor = UIColor(white: 0.16, alpha: 1)
        cancel.configuration = cancelConfiguration
        BoothTheme.styleButton(cancel, title: "返回首页", symbol: "chevron.left", role: .quiet)
        cancel.addAction(UIAction { [weak self] _ in self?.closeHomeEditor() }, for: .touchUpInside)

        let pageTitle = UILabel()
        pageTitle.text = "布置活动首页"
        pageTitle.font = .systemFont(ofSize: 24, weight: .bold)
        pageTitle.textColor = UIColor(white: 0.12, alpha: 1)
        pageTitle.textAlignment = .center
        let pageDetail = UILabel()
        pageDetail.text = "换上背景，写下欢迎语。"
        pageDetail.font = .systemFont(ofSize: 13, weight: .medium)
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
        BoothTheme.styleButton(done, title: "保存首页", symbol: "checkmark", role: .primary)
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
        let previewVeil = homeEditorVeil
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
        homeEditorStart.backgroundColor = accent
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
        BoothTheme.styleSegments(homePreset)
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
        configure(defaultBackground, "简洁背景") { [weak self] in
            self?.draftWelcomeBackground = UIImage(named: "wedding-welcome-cover")
            self?.draftUsesCustomBackground = false
            self?.updateHomeEditorPreview()
        }
        defaultBackground.configuration?.titleLineBreakMode = .byClipping
        defaultBackground.accessibilityLabel = "使用简洁暖白背景"
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
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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
        let studioWelcome = !draftUsesCustomBackground
        homeEditorPreviewImage.isHidden = studioWelcome
        homeEditorVeil.isHidden = studioWelcome
        homeEditorPreviewImage.superview?.backgroundColor = studioWelcome ? BoothTheme.canvas : BoothTheme.stage
        homeEditorHeading.textColor = studioWelcome ? BoothTheme.ink : .white
        homeEditorEyebrow.textColor = studioWelcome ? BoothTheme.accent : .white.withAlphaComponent(0.92)
        homeEditorSubtitle.textColor = studioWelcome ? BoothTheme.secondary : .white.withAlphaComponent(0.9)
        homeEditorMark.textColor = studioWelcome ? BoothTheme.accent : UIColor(red: 1, green: 0.86, blue: 0.57, alpha: 1)
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
        guard let image = printable, camera.capturedImage != nil, !rendering,
              printer.state != .printing,
              PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true else { return }
        // The displayed composition is the output for every destination, including Mijia.
        if printer.mode == .mijiaShare || printer.mode == .mock {
            printer.print(image: image, presenting: self, sourceView: printButton)
            return
        }
        let confirmation = UIAlertController(title: "打印这张照片？", message: "请确认相纸、色带和打印机已准备好。成片包含当前模板和文字。", preferredStyle: .alert)
        confirmation.addAction(UIAlertAction(title: "取消", style: .cancel))
        confirmation.addAction(UIAlertAction(title: "确认打印", style: .default) { [weak self] _ in
            guard let self else { return }
            self.printer.print(image: image, presenting: self, sourceView: self.printButton)
        })
        present(confirmation, animated: true)
    }

    private func makeCaptureTemplateCard() -> UIView {
        selectedTemplateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        selectedTemplateLabel.text = style.weddingTemplate.rawValue
        let change = UIButton(type: .system)
        configure(change, "更换拍摄模板") { [weak self] in self?.showTemplateSelection() }
        change.configuration?.image = UIImage(systemName: "square.grid.2x2")
        change.configuration?.imagePadding = 8
        return card("当前模板", views: [selectedTemplateLabel, change])
    }

    private func showTemplateSelection() {
        guard !busy, printer.state != .printing, templateSelection == nil else { return }
        camera.stop()
        let selector = TemplateSelectionController(style: style)
        selector.onContinue = { [weak self] selected in
            guard let self else { return }
            self.style = selected
            self.selectedPaper = selected.paper
            self.paper.setTitle(selected.paper.rawValue, for: .normal)
            self.paper.configuration?.title = selected.paper.rawValue
            self.frame.selectedSegmentIndex = PhotoFrame.allCases.firstIndex(of: selected.frame) ?? 0
            self.direction.selectedSegmentIndex = PaperDirection.allCases.firstIndex(of: selected.direction) ?? 0
            self.placement.selectedSegmentIndex = PhotoPlacement.allCases.firstIndex(of: selected.placement) ?? 0
            self.printSize.selectedSegmentIndex = PhotoPrintSize.allCases.firstIndex(of: selected.printSize) ?? 0
            self.layout.selectedSegmentIndex = 0
            self.selectedTemplateLabel.text = selected.weddingTemplate.rawValue
            self.removeTemplateSelection()
            self.styleChanged()
            self.enterBooth()
        }
        selector.onBack = { [weak self] in
            guard let self else { return }
            self.removeTemplateSelection()
            if self.welcomeCover.isHidden { self.camera.start() }
        }
        templateSelection = selector
        addChild(selector)
        view.addSubview(selector.view)
        selector.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selector.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selector.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selector.view.topAnchor.constraint(equalTo: view.topAnchor),
            selector.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        selector.didMove(toParent: self)
    }

    private func removeTemplateSelection() {
        guard let selector = templateSelection else { return }
        selector.willMove(toParent: nil)
        selector.view.removeFromSuperview()
        selector.removeFromParent()
        templateSelection = nil
    }

    private func configure(_ button: UIButton, _ title: String, action: @escaping () -> Void) {
        BoothTheme.styleButton(button, title: title)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func updateFilterMenu() {
        filterChoice.configuration?.title = "滤镜 · \(PhotoFilter.allCases[filter.selectedSegmentIndex].rawValue)"
        filterChoice.configuration?.image = UIImage(systemName: "camera.filters")
        filterChoice.menu = UIMenu(children: PhotoFilter.allCases.enumerated().map { index, value in
            UIAction(title: value.rawValue, state: filter.selectedSegmentIndex == index ? .on : .off) { [weak self] _ in
                self?.filter.selectedSegmentIndex = index
                self?.styleChanged()
            }
        })
        intensityControls.isHidden = filter.selectedSegmentIndex == 0
    }
    private func printViews(
        saveStatus: UILabel,
        advanced: UIButton,
        choose: UIButton,
        export: UIButton
    ) -> [UIView] {
        for hint in [printingHelp, printingDetail] {
            hint.font = .preferredFont(forTextStyle: .subheadline)
            hint.textColor = BoothTheme.secondary
            hint.numberOfLines = 0
        }
        #if targetEnvironment(macCatalyst)
        return [mode, printerStatus, printingHelp, printingDetail, choose, export]
        #else
        let diagnostics = UIButton(type: .system)
        configure(diagnostics, "USB 设备检测") { [weak self] in
            self?.showPrinterUSBDiagnostics()
        }
        diagnostics.accessibilityIdentifier = "printer-usb-diagnostics"
        paperSettings.addArrangedSubview(diagnostics)
        paperSettings.addArrangedSubview(label("设备检测仅用于排查连接，不提供 USB 打印。", size: 13))
        return [
            mode,
            printerStatus,
            printingHelp,
            printingDetail,
            choose,
            advanced,
            paperSettings,
            export
        ]
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func showPrinterUSBDiagnostics() {
        guard presentedViewController == nil else { return }
        let navigation = UINavigationController(rootViewController: PrinterUSBDiagnosticsController())
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }
    #endif
    private func selectInspectorPage() {
        for (index, page) in inspectorPages.enumerated() {
            page.isHidden = index != inspectorTabs.selectedSegmentIndex
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    private func photoSizeViews() -> [UIView] {
        #if targetEnvironment(macCatalyst)
        return [
            label("照片旋转", size: 12),
            rotation,
            placement,
            label("完整画面会保留照片四边，比例不同时留白。", size: 13),
            label("USB 打印使用 6 英寸横向相纸。", size: 13)
        ]
        #else
        flexibleFormat.axis = .vertical
        flexibleFormat.spacing = 12
        [label("照片尺寸", size: 13), printSize, label("横竖方向", size: 13), direction,
         label("照片排版", size: 13), layout].forEach { flexibleFormat.addArrangedSubview($0) }
        return [
            label("照片旋转", size: 12),
            rotation,
            placement,
            label("完整画面会保留照片四边，比例不同时留白。", size: 13),
            flexibleFormat,
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
                liveDecoration.isHidden = true
            }
            rendering = false
            stageLabel.text = "准备拍摄"
            editorState.text = "调整会同步到成片。"
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
                self.liveDecoration.isHidden = true
                self.rendering = false
                self.stageLabel.text = "成片预览"
                self.editorState.text = "不满意可以继续调整，或重拍一张。"
                if !self.pendingAutoSave && !self.saving && self.savedRevision != revision {
                    self.saveStatus.text = "当前调整尚未保存。"
                }
                self.updateButtons()
                self.hideCaptureLoading()
                if self.pendingAutoSave && !self.saving {
                    self.pendingAutoSave = false
                    self.savePhoto()
                }
            }
        }
    }
    private func updateButtons() {
        previewPrompt.isHidden = camera.state.isReady || camera.capturedImage != nil || busy
        let printTitle = printer.mode == .mijiaShare ? "去米家打印" : (printer.mode == .mock ? "存到文件" : "打印照片")
        printButton.configuration?.title = printTitle
        printButton.configuration?.image = UIImage(systemName: printer.mode == .mock ? "square.and.arrow.down" : "printer")
        printButton.isHidden = camera.capturedImage == nil
        actionWidth?.constant = camera.capturedImage == nil ? 180 : 320
        timer.isHidden = camera.capturedImage != nil
        exportButton.isHidden = printer.mode != .mock || printer.lastMockPrintURL == nil
        savePanel?.isHidden = view.bounds.width < 850 && camera.capturedImage == nil
        saveCurrent.isHidden = camera.capturedImage == nil || pendingAutoSave || saving || rendering || savedRevision == renderRevision
        saveCurrent.isEnabled = !saving && !rendering && printable != nil && PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true
        deliveryHint.text = camera.capturedImage == nil ? "选好模板和倒计时，轻点拍照。" : (printer.mode == .mijiaShare ? "确认成片后，去米家完成打印。" : "确认成片后，点击下方按钮继续。")
        switch printer.mode {
        case .mijiaShare:
            printingHelp.text = "拍摄后点「去米家打印」，在分享面板选择米家，再确认打印。"
            printingDetail.text = "成片已包含模板和文字。在米家中保留完整图片即可。"
        case .mock:
            printingHelp.text = "将成片另存一份到 App 文件，也可以继续分享。"
            printingDetail.text = "此方式不会发送打印任务。"
        case .airPrint:
            printingHelp.text = "选择支持 AirPrint 的打印机，在系统面板中确认打印。"
            printingDetail.text = "小米照片打印机请使用「米家打印」。"
        case .xiaomiUSB:
            printingHelp.text = "装入 6 英寸相纸和配套色带，确认成片后再打印。"
            printingDetail.text = "打印期间请保持 USB 连接。"
        }
        mode.isEnabled = printer.state != .printing
        #if targetEnvironment(macCatalyst)
        printerChoice.isHidden = printer.mode != .xiaomiUSB
        #else
        printerChoice.isHidden = printer.mode != .airPrint
        #endif
        shutter.isEnabled = camera.state.isReady && !busy && camera.capturedImage == nil
        shutter.isHidden = camera.capturedImage != nil
        retake.isHidden = camera.capturedImage == nil
        retake.isEnabled = camera.capturedImage != nil && !busy && printer.state != .printing
        homeButton.isEnabled = !busy && printer.state != .printing
        printButton.isEnabled = printer.state != .printing && printable != nil && !rendering && PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true
        cameraButton.isEnabled = !busy
        recoverCameraPhoto.isEnabled = !busy && (
            camera.selectedCameraID == CanonUSBPTPClient.cameraID ||
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
            let result = PrintLayoutRenderer.render(image: frame, layout: selectedLayout, style: settings, previewScale: 0.4, includeDecorations: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderingLive = false
                guard self.camera.capturedImage == nil, self.renderRevision == revision else { return }
                self.photo.image = result
                self.photo.isHidden = false
                if self.decorationRevision != revision || self.decorationCanvas != result.size {
                    self.liveDecoration.configure(canvasSize: result.size, style: settings)
                    self.decorationRevision = revision
                    self.decorationCanvas = result.size
                }
                self.liveDecoration.isHidden = false
                self.editorState.text = "实时预览 · \(settings.filter.rawValue)"
            }
        }
    }
    private func savePhoto() {
        guard let image = printable, !rendering, !saving,
              PrintLayoutRenderer.standardCells(style: style)?.isEmpty != true else { return }
        saving = true
        savingRevision = renderRevision
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
                    self?.finishSave("已保存到“图片 / SnapBooth”。", saved: true)
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
                        self?.finishSave(success ? "已保存到系统相册。" : "保存失败：\(error?.localizedDescription ?? "请重试")", saved: success)
                    }
                }
            }
            #endif
        }
    }
    private func finishSave(_ message: String, saved: Bool = false) {
        saving = false
        if saved { savedRevision = savingRevision }
        saveStatus.text = saved && camera.capturedImage != nil && savedRevision != renderRevision
            ? "已保存上一版，当前调整尚未保存。" : message
        if pendingAutoSave && !rendering && camera.capturedImage != nil {
            pendingAutoSave = false
            savePhoto()
        }
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
                self.countdownLabel.show(secondsRemaining: value + 1, totalSeconds: seconds)
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
                self?.shutter.configuration?.title = "拍照"
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
        updateWorkspaceLayout()
        let narrowToolbar = stage.bounds.width < 540
        let homeTitle = narrowToolbar ? nil : "返回首页"
        if homeButton.configuration?.title != homeTitle {
            homeButton.configuration?.title = homeTitle
        }
        shooting.axis = narrowToolbar ? .vertical : .horizontal
        toolbarHeight.constant = narrowToolbar && !timer.isHidden ? 104 : 44
        toolbarSpacer.isHidden = narrowToolbar
    }

    private func setSettingsExpanded(_ expanded: Bool) {
        guard settingsExpanded != expanded else { return }
        settingsExpanded = expanded
        settingsToggle.configuration?.title = expanded ? "收起设置" : "展开设置"
        settingsToggle.configuration?.image = UIImage(systemName: expanded ? "sidebar.right" : "slider.horizontal.3")
        settingsToggle.accessibilityValue = expanded ? "已展开" : "已收起"
        updateWorkspaceLayout()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func updateWorkspaceLayout() {
        let compact = view.bounds.width < 850
        identity.isHidden = compact
        savePanel.isHidden = compact && camera.capturedImage == nil
        if !settingsExpanded, inspector.superview != nil {
            panelWidth.isActive = false
            stageHeight.isActive = false
            // Removing the settings stack avoids zero-width hiding constraints
            // on its nested cards. The stack and all selected values stay alive.
            root.removeArrangedSubview(inspector)
            inspector.removeFromSuperview()
        } else if settingsExpanded, inspector.superview == nil {
            root.addArrangedSubview(inspector)
        }
        if (root.axis == .vertical) != compact {
            panelWidth.isActive = false
            stageHeight.isActive = false
            root.axis = compact ? .vertical : .horizontal
        }
        panelWidth.isActive = settingsExpanded && !compact
        stageHeight.isActive = settingsExpanded && compact
    }
    private func styleChanged() {
        updateFilterMenu()
        style.filter = PhotoFilter.allCases[filter.selectedSegmentIndex]
        style.frame = PhotoFrame.allCases[frame.selectedSegmentIndex]
        style.intensity = strength.value
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
        let illustrated = style.weddingTemplate.hasPhotoWindow
        if illustrated {
            style.direction = .landscape
            direction.selectedSegmentIndex = PaperDirection.allCases.firstIndex(of: .landscape)!
            style.printSize = .six
            printSize.selectedSegmentIndex = PhotoPrintSize.allCases.firstIndex(of: .six)!
            layout.selectedSegmentIndex = 0
        }
        direction.isEnabled = !illustrated
        printSize.isEnabled = !illustrated
        direction.isHidden = illustrated
        printSize.isHidden = illustrated
        layout.isHidden = illustrated
        flexibleFormat.isHidden = illustrated
        let fixed = style.printSize.isID
        layout.isEnabled = !fixed && !illustrated
        placement.isEnabled = !fixed

        #if targetEnvironment(macCatalyst)
        sizeInfo.text = "6 英寸 · 横向照片"
        sizeInfo.textColor = BoothTheme.secondary
        #else
        if let cells = PrintLayoutRenderer.standardCells(style: style) {
            sizeInfo.text = cells.isEmpty ? "所选相纸放不下这张标准照片，请换大相纸或旋转照片。不会自动缩小，已禁用打印。" : "\(style.printSize.detail) · 每纸 \(cells.count) 张 · 2 mm 间距"
            sizeInfo.textColor = cells.isEmpty ? .systemRed : .secondaryLabel
        } else {
            sizeInfo.text = illustrated ? "此模板使用 6 英寸横向相纸。" : "\(style.printSize.rawValue)照片 · \(selectedPaper.rawValue)"
            sizeInfo.textColor = BoothTheme.secondary
        }
        #endif
        renderPhoto()
    }
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: max(size, 13), weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BoothTheme.secondary
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
        BoothTheme.makeSection(title: title, views: views)
    }
}

/// A large, high-contrast countdown that stays out of saved photos.
private final class CountdownBadgeView: UILabel {
    private let progressRing = CAShapeLayer()

    override var text: String? {
        didSet {
            isHidden = text?.isEmpty != false
            accessibilityLabel = text.map { "距离拍摄还有 \($0) 秒" }
            if isHidden { progressRing.removeAllAnimations() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        textColor = .white
        backgroundColor = .clear
        isOpaque = false
        progressRing.fillColor = UIColor.clear.cgColor
        progressRing.strokeColor = UIColor.white.cgColor
        progressRing.lineCap = .round
        layer.addSublayer(progressRing)
        isUserInteractionEnabled = false
        isHidden = true
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func show(secondsRemaining: Int, totalSeconds: Int) {
        guard totalSeconds > 0 else { text = nil; return }
        text = "\(secondsRemaining)"
        let start = CGFloat(secondsRemaining) / CGFloat(totalSeconds)
        let end = CGFloat(max(0, secondsRemaining - 1)) / CGFloat(totalSeconds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressRing.strokeEnd = end
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 1
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        progressRing.add(animation, forKey: "countdownProgress")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.width, bounds.height)
        font = .monospacedDigitSystemFont(ofSize: diameter * 0.55, weight: .bold)
        let lineWidth = max(3, diameter * 0.015)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressRing.frame = bounds
        progressRing.lineWidth = lineWidth
        progressRing.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: max(0, (diameter - lineWidth) / 2),
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
        CATransaction.commit()
    }
}

/// Keeps static artwork and native text sharp while only the camera layer is downsampled.
private final class LiveDecorationView: UIView {
    private let artwork = UIImageView()
    private var canvasSize = CGSize.zero
    private var captions: [PhotoCaption] = []
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        artwork.contentMode = .scaleToFill
        addSubview(artwork)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func configure(canvasSize: CGSize, style: PhotoStyle) {
        self.canvasSize = canvasSize
        artwork.image = PrintLayoutRenderer.decorationImage(canvasSize: canvasSize, style: style)
        captions = style.resolvedCaptions
        labels.forEach { $0.removeFromSuperview() }
        labels = captions.map { caption in
            let label = UILabel()
            label.text = caption.text
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = caption.color.color
            addSubview(label)
            return label
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard canvasSize.width > 0, bounds.width > 0 else { return }
        let canvas = AVMakeRect(aspectRatio: canvasSize, insideRect: bounds)
        artwork.frame = canvas
        for (index, caption) in captions.enumerated() {
            labels[index].font = caption.font.font(size: canvas.height * caption.fontSize)
            labels[index].frame = PrintLayoutRenderer.captionRect(caption, canvasSize: canvas.size)
                .offsetBy(dx: canvas.minX, dy: canvas.minY)
        }
    }
}

private final class CaptionPreviewView: UIImageView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// A dedicated step between the welcome screen and live capture.
private final class TemplateSelectionController: UIViewController, UITextViewDelegate {
    var onContinue: ((PhotoStyle) -> Void)?
    var onBack: (() -> Void)?
    private var draft: PhotoStyle
    private let preview = CaptionPreviewView()
    private let selectionTitle = UILabel()
    private let selectionDetail = UILabel()
    private let bodyStack = UIStackView()
    private let choicesScroll = UIScrollView()
    private let border = UIButton(type: .system)
    private let borderSection = UIStackView()
    private var buttons: [UIButton] = []
    private var choicesWidth: NSLayoutConstraint!
    private var compactPreviewHeight: NSLayoutConstraint!
    private var placeholder = UIImage()
    private let editTabs = UISegmentedControl(items: ["模板", "自定义文案"])
    private let captionControls = UIStackView()
    private var templateControls: UIStackView!
    private let captionPicker = UIButton(type: .system)
    private let captionText = UITextView()
    private let captionFont = UIButton(type: .system)
    private let captionColor = UIButton(type: .system)
    private let captionSize = UISlider()
    private let captionWidth = UISlider()
    private let captionFields = UIStackView()
    private var captionLabels: [UILabel] = []
    private var selectedCaption: Int?
    private let accent = BoothTheme.accent

    init(style: PhotoStyle) {
        draft = style
        if !WeddingTemplate.curated.contains(draft.weddingTemplate) { draft.weddingTemplate = .invitationIllustration }
        draft.paper = .xiaomiSix
        draft.mijiaPaperMode = .sixInch
        draft.direction = .landscape
        draft.printSize = .six
        draft.placement = .fit
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityViewIsModal = true
        view.backgroundColor = BoothTheme.canvas
        view.tintColor = accent
        let back = UIButton(type: .system)
        BoothTheme.styleButton(back, title: "返回", symbol: "chevron.left", role: .quiet)
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        let heading = text("选择照片风格", size: 26, weight: .semibold)
        heading.accessibilityTraits.insert(.header)
        let step = text("01 / 03", size: 13, weight: .medium)
        step.textColor = BoothTheme.secondary
        step.accessibilityLabel = "第 1 步，共 3 步：选择模板"
        step.setContentCompressionResistancePriority(.required, for: .horizontal)
        back.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [back, heading, UIView(), step])
        header.alignment = .center
        header.spacing = 16

        let previewPanel = UIView()
        previewPanel.backgroundColor = BoothTheme.surface
        previewPanel.layer.cornerRadius = 20
        previewPanel.layer.cornerCurve = .continuous
        previewPanel.layer.borderWidth = 1
        previewPanel.layer.borderColor = BoothTheme.line.cgColor
        preview.contentMode = .scaleAspectFit
        preview.isUserInteractionEnabled = true
        preview.onLayout = { [weak self] in self?.layoutCaptionLabels() }
        preview.clipsToBounds = true
        preview.accessibilityLabel = "所选模板成片预览"
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.addSubview(preview)
        selectionTitle.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
        selectionTitle.adjustsFontForContentSizeCategory = true
        selectionTitle.textColor = BoothTheme.ink
        selectionTitle.numberOfLines = 0
        selectionDetail.font = .preferredFont(forTextStyle: .subheadline)
        selectionDetail.adjustsFontForContentSizeCategory = true
        selectionDetail.textColor = BoothTheme.secondary
        selectionDetail.numberOfLines = 0
        let previewInfo = UIStackView(arrangedSubviews: [selectionTitle, selectionDetail])
        previewInfo.axis = .vertical
        previewInfo.spacing = 5
        previewInfo.translatesAutoresizingMaskIntoConstraints = false
        previewPanel.addSubview(previewInfo)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewPanel.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: previewPanel.trailingAnchor, constant: -20),
            preview.topAnchor.constraint(equalTo: previewPanel.topAnchor, constant: 20),
            preview.bottomAnchor.constraint(equalTo: previewInfo.topAnchor, constant: -16),
            previewInfo.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            previewInfo.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            previewInfo.bottomAnchor.constraint(equalTo: previewPanel.bottomAnchor, constant: -20)
        ])
        let choices = UIStackView()
        choices.axis = .vertical
        templateControls = choices
        choices.spacing = 14
        choices.addArrangedSubview(text("选择模板", size: 20, weight: .semibold))
        let intro = text("轻点切换，预览你的成片。", size: 14)
        intro.textColor = BoothTheme.secondary
        choices.addArrangedSubview(intro)
        placeholder = makePlaceholder()
        for rowIndex in 0..<((WeddingTemplate.curated.count + 1) / 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
            for template in WeddingTemplate.curated[(rowIndex * 2)..<min(rowIndex * 2 + 2, WeddingTemplate.curated.count)] {
                let button = UIButton(type: .system)
                BoothTheme.styleButton(button, title: template.rawValue)
                var configuration = button.configuration ?? .plain()
                configuration.imagePlacement = .top
                configuration.imagePadding = 10
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
                configuration.background.cornerRadius = 14
                configuration.imageColorTransformer = nil
                var thumbnailStyle = draft
                thumbnailStyle.weddingTemplate = template
                let rendered = PrintLayoutRenderer.render(image: placeholder, layout: .full, style: thumbnailStyle, previewScale: 0.25)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                configuration.image = UIGraphicsImageRenderer(size: CGSize(width: 140, height: 94), format: format).image { _ in
                    rendered.draw(in: CGRect(x: 0, y: 0, width: 140, height: 94))
                }.withRenderingMode(.alwaysOriginal)
                button.configuration = configuration
                button.configurationUpdateHandler = { button in
                    guard var configuration = button.configuration else { return }
                    let foreground = button.isSelected ? BoothTheme.accent : BoothTheme.ink
                    configuration.baseForegroundColor = foreground
                    configuration.background.backgroundColor = button.isSelected || button.isHighlighted ? BoothTheme.accentSoft : BoothTheme.surface
                    configuration.background.strokeColor = button.isSelected ? BoothTheme.accent : BoothTheme.line
                    configuration.background.strokeWidth = button.isSelected ? 2 : 1
                    let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                        for: .systemFont(ofSize: 14, weight: .semibold), compatibleWith: button.traitCollection)
                    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                        var result = attributes
                        result.font = font
                        result.foregroundColor = foreground
                        return result
                    }
                    button.configuration = configuration
                }
                button.layer.cornerRadius = 14
                button.layer.cornerCurve = .continuous
                button.clipsToBounds = true
                button.accessibilityLabel = "\(template.rawValue)，\(template.detail)"
                button.addAction(UIAction { [weak self] _ in
                    self?.draft.weddingTemplate = template
                    self?.draft.placement = .fit
                    self?.refreshPreview()
                }, for: .touchUpInside)
                buttons.append(button)
                row.addArrangedSubview(button)
            }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(UIView()) }
            choices.addArrangedSubview(row)
        }
        borderSection.axis = .vertical
        borderSection.spacing = 8
        borderSection.addArrangedSubview(text("简约款边框", size: 13, weight: .semibold))
        BoothTheme.styleButton(border, title: "边框", symbol: "chevron.down")
        border.configuration?.imagePlacement = .trailing
        border.showsMenuAsPrimaryAction = true
        border.accessibilityLabel = "简约模板边框颜色"
        borderSection.addArrangedSubview(border)
        choices.addArrangedSubview(borderSection)
        installCaptionControls()
        BoothTheme.styleSegments(editTabs)
        editTabs.selectedSegmentIndex = 0
        editTabs.addAction(UIAction { [weak self] _ in self?.updateEditorTab() }, for: .valueChanged)
        let panel = UIStackView(arrangedSubviews: [editTabs, choices, captionControls])
        panel.axis = .vertical
        panel.spacing = 24
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        panel.backgroundColor = BoothTheme.surface
        panel.layer.cornerRadius = 20
        panel.layer.cornerCurve = .continuous
        panel.layer.borderWidth = 1
        panel.layer.borderColor = BoothTheme.line.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        choicesScroll.keyboardDismissMode = .interactive
        choicesScroll.showsVerticalScrollIndicator = false
        choicesScroll.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: choicesScroll.contentLayoutGuide.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: choicesScroll.contentLayoutGuide.trailingAnchor),
            panel.topAnchor.constraint(equalTo: choicesScroll.contentLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: choicesScroll.contentLayoutGuide.bottomAnchor),
            panel.widthAnchor.constraint(equalTo: choicesScroll.frameLayoutGuide.widthAnchor)
        ])
        updateEditorTab()
        bodyStack.axis = .horizontal
        bodyStack.spacing = 28
        bodyStack.addArrangedSubview(previewPanel)
        bodyStack.addArrangedSubview(choicesScroll)
        choicesWidth = choicesScroll.widthAnchor.constraint(equalToConstant: 400)
        choicesWidth.isActive = true
        compactPreviewHeight = previewPanel.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.34)
        compactPreviewHeight.priority = .defaultHigh

        let continueButton = UIButton(type: .system)
        BoothTheme.styleButton(continueButton, title: "开始拍摄", symbol: "arrow.right", role: .primary)
        continueButton.configuration?.imagePlacement = .trailing
        continueButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 26, bottom: 16, trailing: 26)
        continueButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onContinue?(self.draft)
        }, for: .touchUpInside)
        let note = text("6 英寸横向 · 单张照片", size: 13)
        note.textColor = BoothTheme.secondary
        let footer = UIStackView(arrangedSubviews: [note, UIView(), continueButton])
        footer.alignment = .center
        footer.spacing = 16
        for item in [header, bodyStack, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            bodyStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            bodyStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -20),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
        refreshPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCaptionLabels()
        let compact = view.bounds.width < 900
        if (bodyStack.axis == .vertical) != compact {
            choicesWidth.isActive = false
            compactPreviewHeight.isActive = false
            bodyStack.axis = compact ? .vertical : .horizontal
            if compact { compactPreviewHeight.isActive = true } else { choicesWidth.isActive = true }
        }
    }

    private func refreshPreview() {
        var background = draft
        background.captions = []
        // The editor uses full print resolution; live capture retains its cheaper preview.
        preview.image = PrintLayoutRenderer.render(image: placeholder, layout: .full, style: background)
        rebuildCaptionLabels()
        selectionTitle.text = draft.weddingTemplate.rawValue
        selectionDetail.text = draft.weddingTemplate.detail
        borderSection.isHidden = draft.weddingTemplate.hasPhotoWindow
        refreshBorderMenu()
        for (index, button) in buttons.enumerated() {
            let selected = WeddingTemplate.curated[index] == draft.weddingTemplate
            button.isSelected = selected
            button.setNeedsUpdateConfiguration()
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    private func refreshBorderMenu() {
        let borderless = draft.borderInset == 0
        let current = borderless ? "无边框" : draft.frame.rawValue
        border.configuration?.title = current
        border.accessibilityValue = current
        let none = UIAction(title: "无边框", state: borderless ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.draft.borderInset = 0
            self.draft.placement = .fit
            self.refreshPreview()
        }
        let colors = PhotoFrame.allCases.map { frame in
            UIAction(title: frame.rawValue, state: !borderless && draft.frame == frame ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.draft.frame = frame
                self.draft.borderInset = 54
                self.draft.placement = .fit
                self.refreshPreview()
            }
        }
        border.menu = UIMenu(title: "边框颜色", children: [none] + colors)
    }

    private func updateEditorTab() {
        view.endEditing(true)
        templateControls.isHidden = editTabs.selectedSegmentIndex == 1
        captionControls.isHidden = editTabs.selectedSegmentIndex == 0
        layoutCaptionLabels()
        choicesScroll.setContentOffset(.zero, animated: false)
    }

    private func installCaptionControls() {
        captionControls.axis = .vertical
        captionControls.spacing = 16
        captionControls.addArrangedSubview(text("写下这一刻", size: 20, weight: .semibold))
        let hint = text("轻点预览中的文字可选中，拖动调整位置。", size: 14)
        hint.textColor = BoothTheme.secondary
        captionControls.addArrangedSubview(hint)
        let add = UIButton(type: .system)
        BoothTheme.styleButton(add, title: "添加文案", symbol: "plus")
        add.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var captions = self.draft.resolvedCaptions
            captions.append(PhotoCaption())
            self.draft.captions = captions
            self.selectedCaption = captions.count - 1
            self.rebuildCaptionLabels()
            self.syncCaptionFields()
        }, for: .touchUpInside)
        captionControls.addArrangedSubview(add)
        BoothTheme.styleButton(captionPicker, title: "选择文案", symbol: "chevron.down", role: .quiet)
        captionPicker.configuration?.imagePlacement = .trailing
        captionPicker.showsMenuAsPrimaryAction = true
        captionPicker.accessibilityLabel = "当前编辑的文案"
        captionControls.addArrangedSubview(captionPicker)
        captionFields.axis = .vertical
        captionFields.spacing = 12
        captionText.delegate = self
        captionText.font = .preferredFont(forTextStyle: .body)
        captionText.adjustsFontForContentSizeCategory = true
        captionText.textColor = BoothTheme.ink
        captionText.backgroundColor = BoothTheme.canvas
        captionText.layer.cornerRadius = 12
        captionText.layer.cornerCurve = .continuous
        captionText.layer.borderWidth = 1
        captionText.layer.borderColor = BoothTheme.line.cgColor
        captionText.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        let textHeight = captionText.heightAnchor.constraint(equalToConstant: 132)
        textHeight.priority = UILayoutPriority(999)
        textHeight.isActive = true
        captionText.accessibilityLabel = "文案内容"
        captionFields.addArrangedSubview(captionText)
        captionFields.addArrangedSubview(text("字体风格", size: 13, weight: .semibold))
        BoothTheme.styleButton(captionFont, title: "选择字体", symbol: "chevron.down")
        captionFont.configuration?.imagePlacement = .trailing
        captionFont.showsMenuAsPrimaryAction = true
        captionFont.accessibilityLabel = "文案字体"
        captionFields.addArrangedSubview(captionFont)
        captionFields.addArrangedSubview(text("文字颜色", size: 13, weight: .semibold))
        BoothTheme.styleButton(captionColor, title: "选择颜色", symbol: "chevron.down")
        captionColor.configuration?.imagePlacement = .trailing
        captionColor.showsMenuAsPrimaryAction = true
        captionColor.accessibilityLabel = "文案颜色"
        captionFields.addArrangedSubview(captionColor)
        captionFields.addArrangedSubview(text("字号", size: 13, weight: .semibold))
        captionSize.minimumValue = 0.02
        captionSize.maximumValue = 0.13
        captionSize.minimumTrackTintColor = accent
        captionSize.maximumTrackTintColor = BoothTheme.line
        let sizeHeight = captionSize.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        sizeHeight.priority = UILayoutPriority(999)
        sizeHeight.isActive = true
        captionSize.accessibilityLabel = "文案字号"
        captionSize.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.editCaption { $0.fontSize = CGFloat(self.captionSize.value) }
        }, for: .valueChanged)
        captionFields.addArrangedSubview(captionSize)
        captionFields.addArrangedSubview(text("文本框宽度 · 自动换行", size: 13, weight: .semibold))
        captionWidth.minimumValue = 0.2
        captionWidth.maximumValue = 0.95
        captionWidth.minimumTrackTintColor = accent
        captionWidth.maximumTrackTintColor = BoothTheme.line
        let widthHeight = captionWidth.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        widthHeight.priority = UILayoutPriority(999)
        widthHeight.isActive = true
        captionWidth.accessibilityLabel = "文案宽度"
        captionWidth.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.editCaption { $0.width = CGFloat(self.captionWidth.value) }
        }, for: .valueChanged)
        captionFields.addArrangedSubview(captionWidth)
        let delete = UIButton(type: .system)
        BoothTheme.styleButton(delete, title: "删除这段文案", symbol: "trash", role: .destructive)
        delete.addAction(UIAction { [weak self] _ in
            guard let self, let index = self.selectedCaption else { return }
            var captions = self.draft.resolvedCaptions
            guard captions.indices.contains(index) else { return }
            captions.remove(at: index)
            self.draft.captions = captions
            self.selectedCaption = captions.isEmpty ? nil : min(index, captions.count - 1)
            self.rebuildCaptionLabels()
            self.syncCaptionFields()
        }, for: .touchUpInside)
        captionFields.addArrangedSubview(delete)
        captionControls.addArrangedSubview(captionFields)
        syncCaptionFields()
    }

    private func syncCaptionFields() {
        let captions = draft.resolvedCaptions
        if selectedCaption == nil || !captions.indices.contains(selectedCaption!) {
            selectedCaption = captions.isEmpty ? nil : 0
        }
        refreshCaptionMenu()
        captionFields.isHidden = selectedCaption == nil
        captionPicker.isHidden = captions.isEmpty
        guard let index = selectedCaption, captions.indices.contains(index) else { return }
        let caption = captions[index]
        captionPicker.configuration?.title = "文案 \(index + 1) · \(String(caption.text.prefix(18)))"
        captionText.text = caption.text
        refreshCaptionStyleMenus(caption)
        captionSize.value = Float(caption.fontSize)
        captionWidth.value = Float(caption.width)
    }

    private func refreshCaptionStyleMenus(_ caption: PhotoCaption) {
        captionFont.configuration?.title = caption.font.rawValue
        captionFont.accessibilityValue = caption.font.rawValue
        captionFont.menu = UIMenu(title: "字体风格", children: CaptionFont.allCases.map { font in
            UIAction(title: font.rawValue, state: caption.font == font ? .on : .off) { [weak self] _ in
                self?.editCaption { $0.font = font }
                self?.syncCaptionFields()
            }
        })
        captionColor.configuration?.title = caption.color.rawValue
        captionColor.accessibilityValue = caption.color.rawValue
        captionColor.menu = UIMenu(title: "文字颜色", children: CaptionColor.allCases.map { color in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(color.color, renderingMode: .alwaysOriginal)
            return UIAction(title: color.rawValue, image: swatch, state: caption.color == color ? .on : .off) { [weak self] _ in
                self?.editCaption { $0.color = color }
                self?.syncCaptionFields()
            }
        })
    }

    private func refreshCaptionMenu() {
        let captions = draft.resolvedCaptions
        captionPicker.menu = UIMenu(children: captions.enumerated().map { index, caption in
            UIAction(title: caption.text.isEmpty ? "空文案" : String(caption.text.prefix(24)),
                     state: index == selectedCaption ? .on : .off) { [weak self] _ in
                self?.selectedCaption = index
                self?.syncCaptionFields()
                self?.layoutCaptionLabels()
            }
        })
        if let index = selectedCaption, captions.indices.contains(index) {
            captionPicker.configuration?.title = "文案 \(index + 1) · \(String(captions[index].text.prefix(18)))"
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        editCaption { $0.text = textView.text }
    }

    private func editCaption(_ change: (inout PhotoCaption) -> Void) {
        guard let index = selectedCaption else { return }
        var captions = draft.resolvedCaptions
        guard captions.indices.contains(index) else { return }
        change(&captions[index])
        draft.captions = captions
        refreshCaptionMenu()
        layoutCaptionLabels()
    }

    private func rebuildCaptionLabels() {
        captionLabels.forEach { $0.removeFromSuperview() }
        captionLabels = draft.resolvedCaptions.enumerated().map { index, _ in
            let label = UILabel()
            label.tag = index
            label.numberOfLines = 0
            label.textAlignment = .center
            label.isUserInteractionEnabled = true
            label.layer.cornerRadius = 4
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectCaption(_:))))
            label.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragCaption(_:))))
            preview.addSubview(label)
            return label
        }
        syncCaptionFields()
        layoutCaptionLabels()
    }

    private func layoutCaptionLabels() {
        guard let image = preview.image, preview.bounds.width > 0 else { return }
        let canvas = AVMakeRect(aspectRatio: image.size, insideRect: preview.bounds)
        for (index, caption) in draft.resolvedCaptions.enumerated() where captionLabels.indices.contains(index) {
            let label = captionLabels[index]
            label.frame = PrintLayoutRenderer.captionRect(caption, canvasSize: canvas.size).offsetBy(dx: canvas.minX, dy: canvas.minY)
            label.text = caption.text.isEmpty ? " " : caption.text
            label.font = caption.font.font(size: canvas.height * caption.fontSize)
            label.textColor = caption.color.color
            label.layer.borderWidth = index == selectedCaption && editTabs.selectedSegmentIndex == 1 ? 1 : 0
            label.layer.borderColor = accent.withAlphaComponent(0.6).cgColor
            label.accessibilityLabel = "可拖动文案：\(caption.text)"
        }
    }

    @objc private func selectCaption(_ gesture: UITapGestureRecognizer) {
        selectedCaption = gesture.view?.tag
        editTabs.selectedSegmentIndex = 1
        updateEditorTab()
        syncCaptionFields()
        layoutCaptionLabels()
    }

    @objc private func dragCaption(_ gesture: UIPanGestureRecognizer) {
        guard let index = gesture.view?.tag, let image = preview.image else { return }
        if gesture.state == .began {
            selectedCaption = index
            editTabs.selectedSegmentIndex = 1
            updateEditorTab()
            syncCaptionFields()
            view.endEditing(true)
        }
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        let canvas = AVMakeRect(aspectRatio: image.size, insideRect: preview.bounds)
        guard canvas.width > 0, canvas.height > 0 else { return }
        let translation = gesture.translation(in: preview)
        editCaption { caption in
            let rect = PrintLayoutRenderer.captionRect(caption, canvasSize: canvas.size)
            let halfWidth = caption.width / 2
            let halfHeight = rect.height / canvas.height / 2
            caption.center.x = min(1 - halfWidth, max(halfWidth, rect.midX / canvas.width + translation.x / canvas.width))
            caption.center.y = min(1 - halfHeight, max(halfHeight, rect.midY / canvas.height + translation.y / canvas.height))
        }
        gesture.setTranslation(.zero, in: preview)
    }

    private func makePlaceholder() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { context in
            UIColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIImage(systemName: "person.2.fill")?.withTintColor(UIColor(red: 0.73, green: 0.72, blue: 0.71, alpha: 1), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 440, y: 240, width: 320, height: 210))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ("你的照片会出现在这里" as NSString).draw(in: CGRect(x: 100, y: 505, width: 1000, height: 60), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32, weight: .medium),
                .foregroundColor: UIColor.gray, .paragraphStyle: paragraph
            ])
        }
    }

    private func text(_ value: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
        let style: UIFont.TextStyle = size >= 24 ? .title2 : (size >= 20 ? .headline : .subheadline)
        let label = BoothTheme.makeLabel(value, textStyle: style, weight: weight)
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        return label
    }
}
