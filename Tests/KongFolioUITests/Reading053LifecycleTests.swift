import XCTest
import SwiftUI
import PDFKit
import AppKit
@testable import KongFolio

final class Reading053LifecycleTests: XCTestCase {
    @MainActor func wait(_ predicate:@escaping ()->Bool) async throws {
        for _ in 0..<2000 { if predicate() { return };try await Task.sleep(nanoseconds:5_000_000) }
        throw NSError(domain:"Reading053Lifecycle",code:1,userInfo:[NSLocalizedDescriptionKey:"生成文献验证等待超时"])
    }
    @MainActor func testTenMixedRoundsOfTwentyFilesStayOperable() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio053-mixed-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var files:[URL]=[]
        for i in 0..<16 {
            let file=root.appendingPathComponent("generated-\(i).pdf"),document=PDFDocument()
            let count=i==15 ? 120:3
            for p in 0..<count { let page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:800),for:.mediaBox);document.insert(page,at:p) }
            try document.dataRepresentation()!.write(to:file);files.append(file)
        }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1400,pixelsHigh:1900,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let graphic=NSGraphicsContext(bitmapImageRep:bitmap)!;NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphic
        NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1400,height:1900)).fill()
        for i in 0..<60 { NSColor.black.setFill();NSBezierPath(rect:CGRect(x:40,y:40+i*28,width:1100-i*3,height:5)).fill() }
        NSGraphicsContext.restoreGraphicsState();let image=NSImage(size:NSSize(width:1400,height:1900));image.addRepresentation(bitmap)
        let scan=PDFDocument();scan.insert(PDFPage(image:image)!,at:0);let scanFile=root.appendingPathComponent("generated-scan.pdf");try scan.dataRepresentation()!.write(to:scanFile);files.append(scanFile)
        let encrypted=PDFDocument();encrypted.insert(PDFPage(),at:0);let locked=root.appendingPathComponent("generated-encrypted.pdf");XCTAssertTrue(encrypted.write(to:locked,withOptions:[.userPasswordOption:"generated",.ownerPasswordOption:"owner"]));files.append(locked)
        for i in 0..<2 { let bad=root.appendingPathComponent("generated-corrupt-\(i).pdf");try Data("%PDF-1.7\ninvalid generated fixture".utf8).write(to:bad);files.append(bad) }
        let suite="KongFolio053-memory-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(2,forKey:"KongFolio.maximumLoadedTabs")
        let store=WorkspaceStore(storage:root.appendingPathComponent("Support"),readingDefaults:defaults);store.bootstrap()
        let host=NSHostingView(rootView:RootView(store:store));host.frame=NSRect(x:0,y:0,width:1000,height:700)
        var samples:[Double]=[]
        for round in 0..<10 {
            store.openEach(files)
            let tabs=store.tabs.compactMap(\.workspace).filter{$0.sourceURL != nil}
            XCTAssertEqual(tabs.count,20)
            for workspace in tabs {
                store.select(workspace.id);host.layoutSubtreeIfNeeded()
                try await wait{!workspace.isImporting && !workspace.busy && (workspace.count>0 || workspace.error != nil)}
                if let url=workspace.sourceURL,url.lastPathComponent.contains("encrypted") || url.lastPathComponent.contains("corrupt") { XCTAssertNotNil(workspace.error) }
                else { XCTAssertTrue(workspace.count>0);workspace.selectPage(max(0,workspace.count-1));XCTAssertEqual(workspace.selection,workspace.count-1) }
                store.close(workspace.id)
                try await wait{!store.tabs.contains(where:{$0.id==workspace.id}) || (store.tabs.count==1 && store.activeWorkspace?.count==0)}
                try await Task.sleep(nanoseconds:2_000_000)
            }
            autoreleasepool { host.layoutSubtreeIfNeeded() }
            try await Task.sleep(nanoseconds:30_000_000)
            samples.append(ReadingLifecycleTests().residentMB())
            XCTAssertTrue(store.tabs.count<=1);XCTAssertFalse(store.activeWorkspace?.busy ?? false)
            print("READING053_MIXED_ROUND",round+1,"MB",samples.last!)
        }
        if let first=samples.first,let last=samples.last { XCTAssertTrue(last-first<250,"多轮释放后的内存增长过大") }
        host.rootView=RootView(store:WorkspaceStore(storage:root.appendingPathComponent("Empty")));host.layoutSubtreeIfNeeded()
    }
    @MainActor func testTwoNativeEditorsRetainConcurrentTextWithoutResettingComposition() {
        var text="甲乙丙丁"
        let a=StableInputCoordinator(read:{text},write:{text=$0}),b=StableInputCoordinator(read:{text},write:{text=$0}),va=ComposingTextView(),vb=ComposingTextView()
        va.string="甲新乙丙丁";vb.string="甲乙丙新丁";a.publish(va);b.publish(vb)
        XCTAssertEqual(text,"甲新乙丙新丁")
        va.setMarkedText("中文输入",selectedRange:NSRange(location:4,length:0),replacementRange:NSRange(location:0,length:0));let marked=va.string
        a.synchronize(va);XCTAssertEqual(va.string,marked);XCTAssertTrue(va.hasMarkedText())
    }
}
