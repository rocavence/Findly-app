import Testing
import Foundation
@testable import Findly

@Suite struct ArrangementTests {
    private func item(_ name: String, folder: Bool = false, size: Int = 0, days: Double = 0, category: FileCategory? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/x/\(name)"), name: name, isFolder: folder, isPackage: false,
                 category: category ?? (folder ? .folder : .document), date: Date(timeIntervalSince1970: days * 86_400),
                 size: size, kind: folder ? "Folder" : "Document")
    }

    @Test func foldersFirstThenName() {
        let rows = Arrangement().rows([item("b.txt"), item("Zeta", folder: true), item("a.txt")])
        #expect(rows.map { if case .item(let i) = $0 { i.name } else { "" } } == ["Zeta", "a.txt", "b.txt"])
    }

    @Test func naturalNameOrder() {
        let rows = Arrangement().rows([item("file10"), item("file2"), item("file1")])
        #expect(rows.compactMap { if case .item(let i) = $0 { i.name } else { nil } } == ["file1", "file2", "file10"])
    }

    @Test func sizeDescendingWithNameTieBreak() {
        let a = Arrangement(sort: .size, ascending: false, groupByKind: false)
        let rows = a.rows([item("b", size: 5), item("a", size: 5), item("c", size: 9)])
        #expect(rows.compactMap { if case .item(let i) = $0 { i.name } else { nil } } == ["c", "a", "b"])
    }

    @Test func groupedHasHeadersInFinderOrder() {
        let a = Arrangement(sort: .name, ascending: true, groupByKind: true)
        let rows = a.rows([item("song", category: .audio), item("Docs", folder: true), item("pic", category: .image)])
        #expect(rows == [.header(.folder), .item(item("Docs", folder: true)), .header(.image), .item(item("pic", category: .image)),
                         .header(.audio), .item(item("song", category: .audio))])
    }

    @Test func filterIgnoresCaseAndAccents() {
        let items = [item("Résumé.pdf"), item("notes.txt")]
        #expect(Arrangement.filter(items, "resume").map(\.name) == ["Résumé.pdf"])
        #expect(Arrangement.filter(items, "  ").count == 2)
    }

    @Test func sortColumnRoundTrip() {
        for sort in FileSort.allCases { #expect(FileSort(columnKey: sort.columnKey) == sort) }
        #expect(FileSort(columnKey: "nope") == .name)
    }
}

@Suite struct FileOperationTests {
    @Test func renameValidation() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("findly-\(UUID().uuidString).txt")
        #expect(FileOperations.validate("", for: url) == .empty)
        #expect(FileOperations.validate("a:b", for: url) == .slash)
        #expect(FileOperations.validate("a/b", for: url) == .slash)
        #expect(FileOperations.validate(url.lastPathComponent, for: url) == nil)
    }

    @Test func uniqueNames() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("findly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileOperations.uniqueDestination(for: "a.txt", in: dir, copySuffix: false).lastPathComponent == "a.txt")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: nil)
        #expect(FileOperations.uniqueDestination(for: "a.txt", in: dir, copySuffix: false).lastPathComponent == "a 2.txt")
    }

    @Test func applicationsMergesSystemFolder() {
        #expect(DirectoryReader.sources(for: URL(fileURLWithPath: "/Applications")).count == 2)
        #expect(DirectoryReader.sources(for: URL(fileURLWithPath: "/tmp")).count == 1)
    }
}

@Suite struct EdgeTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func panelFramesHugTheirEdge() {
        #expect(ScreenEdge.right.panelFrame(on: screen, thickness: 300) == CGRect(x: 700, y: 0, width: 300, height: 800))
        #expect(ScreenEdge.top.panelFrame(on: screen, thickness: 200) == CGRect(x: 0, y: 600, width: 1000, height: 200))
        #expect(ScreenEdge.left.offscreenFrame(on: screen, thickness: 300, buffer: 50).maxX == -50)
    }

    @Test func sizeIsClampedTo85Percent() {
        #expect(ScreenEdge.clamp(5000, for: .right, in: screen) == 850)
        #expect(ScreenEdge.clamp(5000, for: .bottom, in: screen) == 680)
        #expect(ScreenEdge.clamp(10, for: .right, in: screen) == 420)
        // On a tiny screen the minimum gives way to the 85% cap.
        #expect(ScreenEdge.clamp(10, for: .right, in: CGRect(x: 0, y: 0, width: 400, height: 300)) == 340)
    }

    @Test func oldPerEdgeSizeMigratesToWidth() {
        let store = UserDefaults.standard
        let saved = (store.object(forKey: "Findly.size.width"), store.object(forKey: "Findly.thickness.right"))
        defer {
            store.set(saved.0, forKey: "Findly.size.width")
            store.set(saved.1, forKey: "Findly.thickness.right")
        }
        store.removeObject(forKey: "Findly.size.width")
        store.set(752.0, forKey: "Findly.thickness.right")
        Defaults.migrate()
        #expect(Defaults.size(for: .left) == 752)
        #expect(store.object(forKey: "Findly.thickness.right") == nil)
    }
}
