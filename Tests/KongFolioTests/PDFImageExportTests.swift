import XCTest
import PDFKit
import ImageIO
@testable import KongFolio

final class PDFImageExportTests: XCTestCase {
    func testSinglePageProducesDecodableImageInEachFormat() throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let document = DocumentServicesTests().fixture()
        let data = try XCTUnwrap(document.dataRepresentation())
        for format in ExportFormat.images {
            let destination = folder.appendingPathComponent("page."+format.suffix)
            let options = ExportOptions(format:format,scope:.current,dpi:72)
            let spec = JobSpec(operation:.configured,source:data,pages:[0],destination:destination,revision:UUID(),exportOptions:options)
            _ = try BackgroundJobs.run(spec) { _ in }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL,nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?,format.type.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            let page = try XCTUnwrap(document.page(at:0))
            let size = try ExportServices.pixels(page,dpi:72)
            XCTAssertEqual(image.width,Int(size.width))
            XCTAssertEqual(image.height,Int(size.height))
        }
    }

    func testMultiplePagesAreNamedWithOriginalPageNumbersInNewFolder() throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let document = DocumentServicesTests().fixture()
        let data = try XCTUnwrap(document.dataRepresentation())
        XCTAssertGreaterThanOrEqual(document.pageCount,2)
        let options = ExportOptions(format:.png,scope:.selected,dpi:72)
        let pages = [0,document.pageCount-1]
        let spec = JobSpec(operation:.configured,source:data,pages:pages,destination:folder,revision:UUID(),exportOptions:options)
        let result = try BackgroundJobs.run(spec) { _ in }
        let output = try XCTUnwrap(result.destination)
        let files = try FileManager.default.contentsOfDirectory(atPath:output.path).sorted()
        XCTAssertEqual(files,pages.map { String(format:"page-%04d.png",$0+1) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),[output.lastPathComponent])
    }

    func testImageExportRestoresHistoricalJPGFormat() throws {
        XCTAssertEqual(try JSONDecoder().decode(ExportFormat.self,from:Data("\"JPG\"".utf8)),.jpeg)
        XCTAssertEqual(try JSONDecoder().decode(ExportFormat.self,from:JSONEncoder().encode(ExportFormat.png)),.png)
    }

    @MainActor func testImageExportEntryStartsOnCurrentPage() throws {
        let folder = try Release027Tests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let workspace = Workspace(storage:folder)
        workspace.document = DocumentServicesTests().fixture()
        workspace.selectPage(1)
        workspace.openImageExport()
        XCTAssertTrue(workspace.showExport)
        XCTAssertEqual(workspace.exportOptions.format,.png)
        XCTAssertEqual(workspace.exportPages,[1])
        workspace.exportPDF()
        XCTAssertEqual(workspace.exportOptions.format,.pdf)
    }
}
