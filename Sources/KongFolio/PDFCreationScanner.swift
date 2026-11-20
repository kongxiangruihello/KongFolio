import SwiftUI
import Quartz
import ImageCaptureCore

@MainActor final class PDFCreationScanner: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    @Published var devices: [ICScannerDevice] = []
    @Published var selectedID: String?
    @Published var message = "正在查找扫描仪…"
    private let browser = ICDeviceBrowser()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-Scan-" + UUID().uuidString, isDirectory: true)
    var selected: ICScannerDevice? { devices.first { $0.uuidString == selectedID } }
    func start() {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { message = error.localizedDescription; return }
        browser.delegate = self; browser.start()
    }
    func stop() { browser.stop(); browser.delegate = nil }
    func cleanUp() { stop(); try? FileManager.default.removeItem(at: directory) }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        guard !devices.contains(where: { $0 === scanner }) else { return }
        devices.append(scanner)
        if selectedID == nil { selectedID = scanner.uuidString }
        message = "在扫描设置中选择色彩、分辨率和裁切范围，扫描完成后可合并创建 PDF。"
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
        if !devices.contains(where: { $0.uuidString == selectedID }) { selectedID = devices.first?.uuidString }
        if devices.isEmpty { message = "尚未连接扫描仪。也可导入已有扫描图片或 PDF。" }
    }
    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if devices.isEmpty { message = "尚未连接扫描仪。也可导入已有扫描图片或 PDF。" }
    }
}

struct PDFScannerView: NSViewRepresentable {
    let device: ICScannerDevice
    let directory: URL
    var onFile: (URL) -> Void
    var onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFile: onFile, onError: onError) }
    func makeNSView(context: Context) -> IKScannerDeviceView {
        let view = IKScannerDeviceView(frame: .zero)
        view.delegate = context.coordinator
        view.transferMode = .fileBased
        view.mode = .advanced
        view.hasDisplayModeAdvanced = true; view.hasDisplayModeSimple = true
        view.downloadsDirectory = directory
        view.displaysDownloadsDirectoryControl = false
        view.displaysPostProcessApplicationControl = false
        view.documentName = "扫描"
        view.scannerDevice = device
        return view
    }
    func updateNSView(_ view: IKScannerDeviceView, context: Context) {
        if view.scannerDevice !== device { view.scannerDevice = device }
    }
    static func dismantleNSView(_ view: IKScannerDeviceView, coordinator: Coordinator) { view.delegate = nil; view.scannerDevice = nil }
    final class Coordinator: NSObject, IKScannerDeviceViewDelegate {
        let onFile: (URL) -> Void
        let onError: (String) -> Void
        init(onFile: @escaping (URL) -> Void, onError: @escaping (String) -> Void) { self.onFile = onFile; self.onError = onError }
        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, fileData data: Data!, error: Error!) {
            if let error { onError(error.localizedDescription) }
            else if let url { onFile(url) }
        }
        func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didEncounterError error: Error!) {
            if let error { onError(error.localizedDescription) }
        }
    }
}
