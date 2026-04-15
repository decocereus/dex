import AVFoundation
import SwiftUI

struct DexCompanionScannerView: View {
    let onScan: (DexCompanionPairingPayload) -> Void
    var onClose: (() -> Void)? = nil

    @State private var scannerError: String?
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true
    @State private var isShowingManualEntry = false
    @State private var manualPayload = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isCheckingPermission {
                ProgressView().tint(.white)
            } else if hasCameraPermission {
                DexCompanionCameraPreview { code, resetScanLock in
                    handleScan(code, resetScanLock: resetScanLock)
                }
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    Spacer()

                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.7), lineWidth: 2)
                        .frame(width: 250, height: 250)

                    Text("Scan the Dex desktop QR from your Mac")
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Button("Paste Payload Instead") {
                        isShowingManualEntry = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.white, in: Capsule())
                }
                .padding(.bottom, 48)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Camera access needed")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Button("Paste Payload Instead") {
                        isShowingManualEntry = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                }
            }
        }
        .task {
            await checkCameraPermission()
        }
        .safeAreaInset(edge: .top) {
            HStack {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .alert("Pairing Error", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK", role: .cancel) { scannerError = nil }
        } message: {
            Text(scannerError ?? "Invalid QR")
        }
        .alert("Paste Pairing Payload", isPresented: $isShowingManualEntry) {
            TextField("Payload JSON", text: $manualPayload, axis: .vertical)
            Button("Import") { handleManualPayload() }
            Button("Cancel", role: .cancel) { manualPayload = "" }
        } message: {
            Text("Paste the full Dex desktop pairing payload JSON if scanning is unavailable.")
        }
    }

    @MainActor
    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            hasCameraPermission = false
        }
        isCheckingPermission = false
    }

    private func handleScan(_ code: String, resetScanLock: @escaping () -> Void) {
        switch validateDexCompanionPairingPayload(code) {
        case .success(let payload):
            onScan(payload)
        case .scanError(let message):
            scannerError = message
            resetScanLock()
        }
    }

    private func handleManualPayload() {
        switch validateDexCompanionPairingPayload(manualPayload) {
        case .success(let payload):
            isShowingManualEntry = false
            manualPayload = ""
            onScan(payload)
        case .scanError(let message):
            scannerError = message
        }
    }
}

private struct DexCompanionCameraPreview: UIViewRepresentable {
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> DexCompanionCameraView {
        let view = DexCompanionCameraView()
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        return view
    }

    func updateUIView(_ uiView: DexCompanionCameraView, context: Context) {}

    static func dismantleUIView(_ uiView: DexCompanionCameraView, coordinator: ()) {
        uiView.stopCamera()
    }
}

private final class DexCompanionCameraView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var scanLocked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func resetScanLock() {
        scanLocked = false
    }

    func stopCamera() {
        session.stopRunning()
    }

    private func configure() {
        backgroundColor = .black
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !scanLocked else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty else {
            return
        }
        scanLocked = true
        onScan?(value)
    }
}
