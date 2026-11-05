import Foundation
import Darwin

private final class PDFProbeBundle053:NSObject {}

enum PDFImportProbe053 {
    struct Result:Codable { var pages:Int;var digest:String }
    struct Region:Codable { var page:Int;var rects:[CGRect];var fingerprint:String? = nil }
    static func region(_ source:SourceRef)throws->Data {
        guard source.invalidPage053 != true,FileManager.default.fileExists(atPath:source.path),let helper=executable else { throw FolioError(message:"来源页图片暂不可用") }
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-region-"+UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:output) }
        let request=try JSONEncoder().encode(Region(page:source.page,rects:source.rects,fingerprint:source.fingerprint)).base64EncodedString()
        try run(helper,arguments:["--region",source.path,output.path,request],timeout:15)
        let bytes=try Data(contentsOf:output)
        guard SignatureImage.loadData(bytes) != nil else { throw FolioError(message:"来源区域图片无法解码") };return bytes
    }
    static var executable:URL? {
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KongFolioPDFProbe")
        let sibling=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("KongFolioPDFProbe")
        var candidates=[bundled,sibling]
        if AppEnvironment.isTestRun {
            var directory=Bundle(for:PDFProbeBundle053.self).bundleURL
            for _ in 0..<4 { candidates.append(directory.appendingPathComponent("KongFolioPDFProbe"));directory=directory.deletingLastPathComponent() }
        }
        return candidates.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    static func inspect(_ source:URL,timeout:TimeInterval=45,helper:URL? = nil)throws->Result {
        guard let helper=helper ?? executable else { throw FolioError(message:"PDF 检查组件缺失，请重新安装完整版本") }
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-probe-"+UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:output) }
        try run(helper,arguments:[source.path,output.path],timeout:timeout)
        let result=try JSONDecoder().decode(Result.self,from:Data(contentsOf:output))
        guard result.pages>0,result.digest.count==64 else { throw FolioError(message:"PDF 检查结果无效") };return result
    }
    private static func run(_ helper:URL,arguments:[String],timeout:TimeInterval)throws {
        let child=Process();child.executableURL=helper;child.arguments=arguments
        child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        try Task.checkCancellation();try child.run()
        defer { if child.isRunning { kill(child.processIdentifier,SIGKILL);child.waitUntilExit() } }
        let deadline=Date().addingTimeInterval(timeout)
        while child.isRunning {
            try Task.checkCancellation()
            if Date()>=deadline { child.terminate();throw FolioError(message:"这份 PDF 解析超过时限，已跳过；可以继续阅读其他文件") }
            Thread.sleep(forTimeInterval:0.025)
        }
        guard child.terminationStatus==0 else { throw FolioError(message:"PDF 无法安全解析，可能损坏或需要密码；其他文献不受影响") }
    }
}
