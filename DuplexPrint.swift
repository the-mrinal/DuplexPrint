import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct DuplexPrintApp: App {
    @StateObject private var controller = PrintController()

    init() {
        // Hidden regression harness: `DuplexPrint --selftest` checks the pure
        // maths and the split engine, then exits without opening a window.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        // Hidden docs harness: `DuplexPrint --screenshots <dir>` renders the
        // main screens to PNGs (for the README) and exits. No window needed.
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots"),
           i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                ScreenshotMaker.run(outDir: CommandLine.arguments[i + 1])
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 760)
        }
    }
}

// MARK: - Self-test (run with --selftest; exits 1 on first failure)

enum SelfTest {
    static func run() {
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS  \(what)" : "FAIL  \(what)")
            if !ok { exit(1) }
        }

        // Split sizes — duplex snaps every non-final part to an even count.
        check(PrintController.partSizes(pages: 187, parts: 4, mode: .duplex) == [48, 48, 48, 43], "partSizes 187/4 duplex")
        check(PrintController.partSizes(pages: 187, parts: 4, mode: .normal) == [47, 47, 47, 46], "partSizes 187/4 normal")
        check(PrintController.partSizes(pages: 10, parts: 4, mode: .duplex) == [4, 4, 2], "partSizes 10/4 duplex")
        check(PrintController.partSizes(pages: 5, parts: 2, mode: .duplex) == [4, 1], "partSizes 5/2 duplex")
        check(PrintController.partSizes(pages: 8, parts: 2, mode: .duplex) == [4, 4], "partSizes 8/2 duplex")

        // Range parsing — order kept, duplicates dropped, garbage rejected.
        check(PrintController.parseRanges("5-20, 35, 40-42", pageCount: 50)?.count == 20, "parseRanges count")
        check(PrintController.parseRanges("3, 1-2, 3", pageCount: 10) == [3, 1, 2], "parseRanges order+dupes")
        check(PrintController.parseRanges("0-2", pageCount: 10) == nil, "parseRanges rejects 0")
        check(PrintController.parseRanges("5-", pageCount: 10) == nil, "parseRanges rejects open range")
        check(PrintController.parseRanges("9-3", pageCount: 10) == nil, "parseRanges rejects reversed")
        check(PrintController.parseRanges("abc", pageCount: 10) == nil, "parseRanges rejects text")
        check(PrintController.parseRanges("11", pageCount: 10) == nil, "parseRanges rejects out of bounds")
        check(PrintController.rangeLabel([5, 6, 7, 12, 40, 41]) == "5–7, 12, 40–41", "rangeLabel")

        // CUPS options: normal mode must never filter pages but must still pin
        // the output order (the L130 PPD default is Reverse).
        let dup1 = PrintController.jobOptions(mode: .duplex, evenPass: false, isEpson: true,
                                              quality: "Normal", blackAndWhite: true, paper: "A4",
                                              reverseEvens: true, rotateEvens: true)
        let dup2 = PrintController.jobOptions(mode: .duplex, evenPass: true, isEpson: true,
                                              quality: "Normal", blackAndWhite: true, paper: "A4",
                                              reverseEvens: true, rotateEvens: true)
        let nrm = PrintController.jobOptions(mode: .normal, evenPass: false, isEpson: true,
                                             quality: "Normal", blackAndWhite: true, paper: "A4",
                                             reverseEvens: true, rotateEvens: true)
        check(dup1.contains("page-set=odd") && dup1.contains("OutputOrder=Normal")
              && !dup1.contains("orientation-requested=6"), "jobOptions duplex pass 1")
        check(dup2.contains("page-set=even") && dup2.contains("OutputOrder=Reverse")
              && dup2.contains("orientation-requested=6"), "jobOptions duplex pass 2 calibrated")
        check(!nrm.contains("page-set=odd") && !nrm.contains("page-set=even")
              && nrm.contains("OutputOrder=Normal") && nrm.contains("EPIJ_BSSv=0")
              && !nrm.contains("orientation-requested=6"), "jobOptions normal mode")
        check(dup1.contains("EPIJ_Qual=303"), "quality Normal → EPIJ 303")
        let fe = PrintController.jobOptions(mode: .normal, evenPass: false, isEpson: true,
                                            quality: "Fast Economy", blackAndWhite: false, paper: "A4",
                                            reverseEvens: false, rotateEvens: false)
        let hq = PrintController.jobOptions(mode: .normal, evenPass: false, isEpson: true,
                                            quality: "High Quality", blackAndWhite: false, paper: "A4",
                                            reverseEvens: false, rotateEvens: false)
        check(fe.contains("EPIJ_Qual=301") && hq.contains("EPIJ_Qual=306"), "full Epson quality ladder mapped")

        // A job.json written before v4 (none of the new keys) must still decode
        // — and must come back as a duplex job.
        let oldJSON = """
        {"id":"OLD1","pdfPath":"/tmp/x.pdf","originalName":"old.pdf","pageCount":187,
         "printer":"EPSON_L130_Series_2","quality":"Normal","blackAndWhite":true,"paper":"A4",
         "reverseEvens":false,"rotateEvens":false,"pass":1,"sheetsCompleted":14,
         "awaitingFlip":false,"passRangeEnd":181,"updatedAt":773500000}
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .deferredToDate
        let old = try? dec.decode(SavedState.self, from: oldJSON)
        check(old != nil, "old job.json decodes")
        check(old?.mode == .duplex && old?.bookID == nil, "old job defaults to duplex")

        // Real split: 6-page PDF → 2 parts of 3+3, plus an out-of-order extract.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-src.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        if let ctx = CGContext(tmp as CFURL, mediaBox: &box, nil) {
            for i in 1...6 {
                ctx.beginPDFPage(nil)
                let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.current = ns
                NSAttributedString(string: "Selftest page \(i)",
                                   attributes: [.font: NSFont.systemFont(ofSize: 24)])
                    .draw(at: NSPoint(x: 100, y: 400))
                NSGraphicsContext.current = nil
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        let bookID = "selftest-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: PrintController.bookDir(bookID)) }
        let sem = DispatchSemaphore(value: 0)
        var built = false
        Task.detached {
            built = await PrintController.buildPartPDFs(bookID: bookID, sourcePath: tmp.path,
                                                        pagesPerPart: [[1, 2, 3], [6, 4]])
            sem.signal()
        }
        sem.wait()
        check(built, "buildPartPDFs succeeds")
        let p1 = PDFDocument(url: PrintController.partURL(bookID: bookID, index: 1))
        let p2 = PDFDocument(url: PrintController.partURL(bookID: bookID, index: 2))
        check(p1?.pageCount == 3 && p2?.pageCount == 2, "part page counts")
        check(p1?.page(at: 0)?.string?.contains("page 1") == true, "part 1 starts at page 1")
        check(p2?.page(at: 0)?.string?.contains("page 6") == true, "extract keeps typed order")
        check(p2?.page(at: 1)?.string?.contains("page 4") == true, "extract keeps typed order (2)")

        print("All self-tests passed.")
    }
}

// MARK: - Model

enum Stage {
    case setup
    case split               // full-screen split/extract workshop for the loaded PDF
    case book(String)        // detail page for one book (by id): print parts from here
    case confirmResume
    case printing(pass: Int)
    case flip
    case done
    case failed(String)
}

enum PrintMode: String, Codable {
    case duplex   // two-sided: odd pages, flip, even pages
    case normal   // one side per sheet, single pass
}

// Everything needed to resume a print run after a crash, reboot, or app quit.
// One of these lives on disk per unfinished job; it is deleted only when both
// sides have fully printed (or the user explicitly deletes it).
struct SavedState: Codable {
    var id: String
    var pdfPath: String        // app-private copy of the document
    var originalName: String
    var pageCount: Int
    var printer: String
    var quality: String
    var blackAndWhite: Bool
    var paper: String
    var reverseEvens: Bool     // calibration, frozen at job creation
    var rotateEvens: Bool      // calibration, frozen at job creation
    var pass: Int              // 1 = odd side, 2 = even side
    var sheetsCompleted: Int   // fully printed sheets in the current pass
    var awaitingFlip: Bool
    var jobID: String?
    var jobBaseSheets: Int?    // sheets completed BEFORE the live CUPS job started (for re-attach math)
    var passRangeEnd: Int?     // cap for pass-1 resubmits when the tail was printed out-of-band
    var updatedAt: Date
    // Optional so job.json files written by older versions still decode.
    var printMode: PrintMode?  // nil = duplex (the only mode that existed before v4)
    var bookID: String?        // owning book when this job prints a split/extracted part
    var partIndex: Int?        // 1-based part number within that book

    var mode: PrintMode { printMode ?? .duplex }
}

// A "book" is a PDF the user split into parts (or extracted pages from).
// Parts live as part-<index>.pdf next to book.json; each is printed as an
// ordinary job, and the book remembers which parts are done.
struct BookPart: Codable {
    var index: Int          // 1-based
    var startPage: Int      // in the ORIGINAL document's numbering
    var endPage: Int
    var printed: Bool
    var label: String?      // extraction: "pages 5–20, 35"; nil → "pages start–end"
    var pages: Int?         // actual page count when not contiguous (extractions)

    var pageRangeLabel: String { label ?? (startPage == endPage ? "page \(startPage)" : "pages \(startPage)–\(endPage)") }
    var size: Int { pages ?? (endPage - startPage + 1) }
}

struct Book: Codable, Identifiable {
    var id: String
    var originalName: String
    var pageCount: Int      // original document
    var printMode: PrintMode // mode the part boundaries were snapped for — frozen
    var parts: [BookPart]
    var createdAt: Date
    var isExtraction: Bool? // single-part "just these pages" book

    var printedCount: Int { parts.filter(\.printed).count }
}

@MainActor
final class PrintController: ObservableObject {
    @Published var stage: Stage = .setup
    @Published var pdfURL: URL?
    @Published var pageCount = 0
    @Published var printers: [String] = []
    @Published var selectedPrinter = "" {
        didSet { Task { await detectPrinterKind() } }
    }
    @Published var isEpson = false
    @Published var statusLine = ""
    @Published var elapsedSeconds = 0

    // Settings chosen once, applied to both passes (remembered across launches)
    @Published var quality = UserDefaults.standard.string(forKey: "quality") ?? "Normal" {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    @Published var blackAndWhite = UserDefaults.standard.bool(forKey: "blackAndWhite") {
        didSet { UserDefaults.standard.set(blackAndWhite, forKey: "blackAndWhite") }
    }
    @Published var paper = UserDefaults.standard.string(forKey: "paper") ?? "A4" {
        didSet { UserDefaults.standard.set(paper, forKey: "paper") }
    }
    @Published var reverseEvens = UserDefaults.standard.bool(forKey: "reverseEvens") {
        didSet { UserDefaults.standard.set(reverseEvens, forKey: "reverseEvens") }
    }
    @Published var rotateEvens = UserDefaults.standard.bool(forKey: "rotateEvens") {
        didSet { UserDefaults.standard.set(rotateEvens, forKey: "rotateEvens") }
    }
    @Published var printMode: PrintMode =
        PrintMode(rawValue: UserDefaults.standard.string(forKey: "printMode") ?? "") ?? .duplex {
        didSet { UserDefaults.standard.set(printMode.rawValue, forKey: "printMode") }
    }

    @Published var jobs: [SavedState] = []
    @Published var books: [Book] = []
    @Published var isSplitting = false
    @Published var pendingResumeSheet = 1
    @Published var progressDone = 0          // sheets safely finished this pass
    @Published var progressCurrent: Int?     // sheet the printer is working on now

    private var pendingJob: SavedState?
    private var previewDoc: PDFDocument?
    private var currentJobID: String?
    private var runToken = 0
    private var caffeinate: Process?
    private var passIsEven = false
    private var passFilteredOffset = 0   // sheets already completed by earlier auto-resumed jobs in this pass
    private var activeState: SavedState?

    // MARK: Persistent job store (survives app quit, reboot, crashes)

    nonisolated private static var stateDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DuplexPrint", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var jobsDir: URL {
        let d = stateDir.appendingPathComponent("jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func jobDir(_ id: String) -> URL { jobsDir.appendingPathComponent(id, isDirectory: true) }

    func loadJobs() {
        let fm = FileManager.default
        var list: [SavedState] = []
        for id in (try? fm.contentsOfDirectory(atPath: Self.jobsDir.path)) ?? [] {
            let f = Self.jobDir(id).appendingPathComponent("job.json")
            if let data = try? Data(contentsOf: f),
               let st = try? JSONDecoder().decode(SavedState.self, from: data),
               fm.fileExists(atPath: st.pdfPath) {
                list.append(st)
            }
        }
        jobs = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveState() {
        guard var st = activeState else { return }
        st.updatedAt = Date()
        activeState = st
        let dir = Self.jobDir(st.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: dir.appendingPathComponent("job.json"), options: .atomic)
        }
        if let i = jobs.firstIndex(where: { $0.id == st.id }) { jobs[i] = st }
        else { jobs.insert(st, at: 0) }
    }

    /// Called only when a job's final pass has fully printed.
    private func clearState() {
        if let st = activeState {
            // If this job printed a book part, remember the part as done.
            if let bid = st.bookID, let pi = st.partIndex,
               var book = books.first(where: { $0.id == bid }),
               let idx = book.parts.firstIndex(where: { $0.index == pi }) {
                book.parts[idx].printed = true
                saveBook(book)
            }
            deleteJob(st)
        }
        activeState = nil
    }

    func deleteJob(_ st: SavedState) {
        try? FileManager.default.removeItem(at: Self.jobDir(st.id))
        jobs.removeAll { $0.id == st.id }
        if activeState?.id == st.id { activeState = nil }
    }

    // MARK: Book store (split / extracted PDFs)

    nonisolated static var booksDir: URL {
        let d = stateDir.appendingPathComponent("books", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static func bookDir(_ id: String) -> URL { booksDir.appendingPathComponent(id, isDirectory: true) }
    nonisolated static func partURL(bookID: String, index: Int) -> URL {
        bookDir(bookID).appendingPathComponent("part-\(index).pdf")
    }

    func loadBooks() {
        let fm = FileManager.default
        var list: [Book] = []
        for id in (try? fm.contentsOfDirectory(atPath: Self.booksDir.path)) ?? [] {
            let f = Self.bookDir(id).appendingPathComponent("book.json")
            if let data = try? Data(contentsOf: f),
               let b = try? JSONDecoder().decode(Book.self, from: data) {
                list.append(b)
            }
        }
        books = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveBook(_ b: Book) {
        let dir = Self.bookDir(b.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(b) {
            try? data.write(to: dir.appendingPathComponent("book.json"), options: .atomic)
        }
        if let i = books.firstIndex(where: { $0.id == b.id }) { books[i] = b }
        else { books.insert(b, at: 0) }
    }

    enum PartStatus {
        case notPrinted
        case inProgress(SavedState)
        case printed
    }

    /// Derived, never stored twice: an unfinished job for the part wins,
    /// otherwise the book's own printed flag decides.
    func status(of part: BookPart, in book: Book) -> PartStatus {
        if let job = jobs.first(where: { $0.bookID == book.id && $0.partIndex == part.index }) {
            return .inProgress(job)
        }
        return part.printed ? .printed : .notPrinted
    }

    /// "Delete" on a single part: forget any unfinished job and clear the
    /// printed flag. The part PDF stays, so it can always be printed again.
    func resetPart(_ book: Book, _ part: BookPart) {
        for job in jobs.filter({ $0.bookID == book.id && $0.partIndex == part.index }) {
            if activeState?.id == job.id { cancelPrinting() }
            deleteJob(job)
        }
        if var b = books.first(where: { $0.id == book.id }),
           let idx = b.parts.firstIndex(where: { $0.index == part.index }) {
            b.parts[idx].printed = false
            saveBook(b)
        }
    }

    /// Removes the book, its part PDFs, and any unfinished jobs printing its parts.
    func deleteBook(_ b: Book) {
        if let st = activeState, st.bookID == b.id { cancelPrinting() }
        for job in jobs.filter({ $0.bookID == b.id }) { deleteJob(job) }
        try? FileManager.default.removeItem(at: Self.bookDir(b.id))
        books.removeAll { $0.id == b.id }
    }

    /// If the printer is actively working on one of our jobs (e.g. the app was
    /// quit and reopened mid-print), attach to it and show the printing screen.
    func autoAttachIfPrinting() async {
        guard case .setup = stage else { return }
        for st in jobs where st.jobID != nil {
            let q = await Self.sh("/usr/bin/lpstat", ["-o", st.printer])
            if q.out.contains(st.jobID!) {
                resume(st)
                return
            }
        }
    }

    /// One line describing every setting the next/running job uses.
    var settingsSummary: String {
        let mode = printMode == .duplex ? "Two-sided" : "One side per sheet"
        let colour = blackAndWhite ? "Black & White" : "Colour"
        let name = selectedPrinter.replacingOccurrences(of: "_", with: " ")
        return "\(mode) · \(paper) · \(quality) quality · \(colour) · \(name)"
    }

    var sheetCount: Int { printMode == .normal ? pageCount : (pageCount + 1) / 2 }
    var hasUnpairedSheet: Bool { printMode == .duplex && pageCount % 2 == 1 && pageCount > 1 }

    // The Epson driver's full quality ladder, fastest/lightest → slowest/darkest,
    // named exactly as Epson's own print dialog names them.
    let qualities = ["Fast Economy", "Economy", "Draft", "Normal", "Fine", "Quality", "High Quality", "Best"]
    let papers = ["A4", "Letter", "A5", "B5", "Legal"]

    // MARK: Shell helper

    nonisolated private static func sh(_ path: String, _ args: [String]) async -> (out: String, code: Int32) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (String(data: d, encoding: .utf8) ?? "", proc.terminationStatus))
            }
            do { try p.run() } catch {
                cont.resume(returning: ("\(error.localizedDescription)", -1))
            }
        }
    }

    // MARK: Printer discovery

    func refreshPrinters() async {
        let list = await Self.sh("/usr/bin/lpstat", ["-a"])
        var names: [String] = []
        for line in list.out.split(separator: "\n") {
            if let first = line.split(separator: " ").first { names.append(String(first)) }
        }
        printers = names
        let def = await Self.sh("/usr/bin/lpstat", ["-d"])
        if let colon = def.out.range(of: ": ") {
            let name = def.out[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if names.contains(name) { selectedPrinter = name }
        }
        if selectedPrinter.isEmpty, let first = names.first { selectedPrinter = first }
    }

    func detectPrinterKind() async {
        guard !selectedPrinter.isEmpty else { return }
        let opts = await Self.sh("/usr/bin/lpoptions", ["-p", selectedPrinter, "-l"])
        isEpson = opts.out.contains("EPIJ_Qual")
    }

    // MARK: Document

    func setDocument(_ url: URL) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            stage = .failed("That file couldn't be opened as a PDF. Please choose a PDF document.")
            return
        }
        pdfURL = url
        pageCount = doc.pageCount
    }

    // MARK: Splitting & extraction

    /// Sizes for splitting `pages` into `parts` roughly equal chunks. In duplex
    /// mode every part except the last gets an EVEN page count, so each part
    /// starts on a fresh sheet (a sheet's back must never bleed into the next
    /// part). May return fewer chunks than requested, never empty ones.
    nonisolated static func partSizes(pages: Int, parts: Int, mode: PrintMode) -> [Int] {
        guard pages > 0, parts > 0 else { return [] }
        var target = (pages + parts - 1) / parts
        if mode == .duplex && target % 2 == 1 { target += 1 }
        var sizes: [Int] = []
        var remaining = pages
        while remaining > 0 {
            let n = min(target, remaining)
            sizes.append(n)
            remaining -= n
        }
        return sizes
    }

    /// Parses "5-20, 35, 40-42" against the document. Pages come back in the
    /// order typed, duplicates dropped; nil if any token is malformed or out
    /// of range.
    nonisolated static func parseRanges(_ s: String, pageCount: Int) -> [Int]? {
        let tokens = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty else { return nil }
        var pages: [Int] = []
        var seen = Set<Int>()
        for t in tokens {
            let bounds = t.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 1, let p = Int(bounds[0]), (1...pageCount).contains(p) {
                if seen.insert(p).inserted { pages.append(p) }
            } else if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]),
                      a <= b, a >= 1, b <= pageCount {
                for p in a...b where seen.insert(p).inserted { pages.append(p) }
            } else {
                return nil
            }
        }
        return pages
    }

    /// "5–20, 35, 40–42" from an ordered page list, condensing ascending runs.
    nonisolated static func rangeLabel(_ pages: [Int]) -> String {
        var runs: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count && pages[j + 1] == pages[j] + 1 { j += 1 }
            runs.append(i == j ? "\(pages[i])" : "\(pages[i])–\(pages[j])")
            i = j + 1
        }
        return runs.joined(separator: ", ")
    }

    /// Copies the given 1-based pages of the source PDF into one new PDF per
    /// part. Returns false (after which the caller cleans up) if the source
    /// can't be read or a part can't be written — e.g. a protected PDF.
    nonisolated static func buildPartPDFs(bookID: String, sourcePath: String,
                                                  pagesPerPart: [[Int]]) async -> Bool {
        guard let src = PDFDocument(url: URL(fileURLWithPath: sourcePath)) else { return false }
        try? FileManager.default.createDirectory(at: bookDir(bookID), withIntermediateDirectories: true)
        for (i, pages) in pagesPerPart.enumerated() {
            let out = PDFDocument()
            for p in pages {
                // Insert a COPY — inserting the live page would re-parent it
                // out of the source document while we're still reading it.
                guard let page = src.page(at: p - 1)?.copy() as? PDFPage else { return false }
                out.insert(page, at: out.pageCount)
            }
            guard out.write(to: partURL(bookID: bookID, index: i + 1)) else { return false }
        }
        return true
    }

    func enterSplit() {
        guard pdfURL != nil, pageCount >= 2 else { return }
        stage = .split
    }

    private func createBook(_ book: Book, pagesPerPart: [[Int]], sourcePath: String) {
        isSplitting = true
        Task {
            let ok = await Self.buildPartPDFs(bookID: book.id, sourcePath: sourcePath,
                                              pagesPerPart: pagesPerPart)
            isSplitting = false
            if ok {
                saveBook(book)
                stage = .book(book.id)   // switch screens BEFORE clearing the
                pdfURL = nil             // document — the split screen must not
                pageCount = 0            // re-render against an empty document
            } else {
                try? FileManager.default.removeItem(at: Self.bookDir(book.id))
                stage = .failed("This PDF couldn't be split — it may be protected or damaged. You can still print it whole.")
            }
        }
    }

    /// Split the loaded PDF at explicit start pages (starts[0] must be 1,
    /// strictly increasing). The split screen builds this list — evenly at
    /// first, then nudged by the user part by part.
    func splitLoadedDocument(atStarts starts: [Int]) {
        guard let url = pdfURL, !isSplitting,
              starts.count >= 2, starts.first == 1, starts.last! <= pageCount,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return }
        var parts: [BookPart] = []
        var pagesPerPart: [[Int]] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : pageCount
            parts.append(BookPart(index: i + 1, startPage: start, endPage: end, printed: false))
            pagesPerPart.append(Array(start...end))
        }
        let book = Book(id: UUID().uuidString, originalName: url.lastPathComponent,
                        pageCount: pageCount, printMode: printMode, parts: parts,
                        createdAt: Date(), isExtraction: false)
        createBook(book, pagesPerPart: pagesPerPart, sourcePath: url.path)
    }

    func extractPages(_ spec: String) {
        guard let url = pdfURL, !isSplitting,
              let pages = Self.parseRanges(spec, pageCount: pageCount), !pages.isEmpty else { return }
        let part = BookPart(index: 1, startPage: pages.min() ?? 1, endPage: pages.max() ?? 1,
                            printed: false, label: "pages \(Self.rangeLabel(pages))", pages: pages.count)
        let book = Book(id: UUID().uuidString, originalName: url.lastPathComponent,
                        pageCount: pageCount, printMode: printMode, parts: [part],
                        createdAt: Date(), isExtraction: true)
        createBook(book, pagesPerPart: [pages], sourcePath: url.path)
    }

    // MARK: Job options

    private func jobOptions(evenPass: Bool) -> [String] {
        Self.jobOptions(mode: printMode, evenPass: evenPass, isEpson: isEpson,
                        quality: quality, blackAndWhite: blackAndWhite, paper: paper,
                        reverseEvens: reverseEvens, rotateEvens: rotateEvens)
    }

    nonisolated static func jobOptions(mode: PrintMode, evenPass: Bool, isEpson: Bool,
                                       quality: String, blackAndWhite: Bool, paper: String,
                                       reverseEvens: Bool, rotateEvens: Bool) -> [String] {
        var o: [String] = ["-o", "PageSize=\(paper)"]
        if isEpson {
            // PPD: EPIJ_Qual 301 FastEconomy / 302 Economy / 308 Draft /
            // 303 Normal (default) / 304 Fine / 305 Quality / 306 HighQuality / 307 Best
            let map = ["Fast Economy": "301", "Economy": "302", "Draft": "308",
                       "Normal": "303", "Fine": "304", "Quality": "305",
                       "High Quality": "306", "Best": "307"]
            o += ["-o", "EPIJ_Qual=\(map[quality] ?? "303")"]
            o += ["-o", "EPIJ_BSSv=0"]   // never skip blank pages: it would shift front/back pairing
            o += ["-o", blackAndWhite ? "EPIJ_Ink_=0" : "EPIJ_Ink_=1"]
            if blackAndWhite { o += ["-o", "ColorModel=Mono"] }
        } else {
            // Generic printers only understand IPP draft(3)/normal(4)/high(5).
            let map = ["Fast Economy": "3", "Economy": "3", "Draft": "3",
                       "Normal": "4", "Fine": "4", "Quality": "5",
                       "High Quality": "5", "Best": "5"]
            o += ["-o", "print-quality=\(map[quality] ?? "4")"]
            o += ["-o", blackAndWhite ? "print-color-mode=monochrome" : "print-color-mode=color"]
        }
        if mode == .duplex {
            o += ["-o", evenPass ? "page-set=even" : "page-set=odd"]
        }
        // The Epson PPD's DefaultOutputOrder is Reverse — always pin the order
        // explicitly or pages come out back-to-front.
        let wantReverse = mode == .duplex && evenPass && reverseEvens
        if isEpson {
            o += ["-o", "OutputOrder=\(wantReverse ? "Reverse" : "Normal")"]
        } else {
            o += ["-o", "outputorder=\(wantReverse ? "reverse" : "normal")"]
        }
        if mode == .duplex && evenPass && rotateEvens { o += ["-o", "orientation-requested=6"] }
        return o
    }

    // MARK: Printing flow

    // Keep the Mac (and its USB ports) awake while a print run is in progress.
    // A sleeping Mac cuts USB power, which drops the printer connection mid-job.
    private func startKeepAwake() {
        guard caffeinate == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-ims"]
        try? p.run()
        caffeinate = p
    }

    private func stopKeepAwake() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    func startPrinting() {
        guard let url = pdfURL else { return }
        startJob(source: url, displayName: url.lastPathComponent)
    }

    /// Prints one part of a book through the ordinary job pipeline. The
    /// confirmation sheet has already let the user check every setting
    /// (it defaults the mode to the one the book was snapped for).
    func printPart(_ book: Book, _ part: BookPart) {
        let name = book.isExtraction == true
            ? "\(book.originalName) — extracted pages"
            : "\(book.originalName) — Part \(part.index) of \(book.parts.count)"
        startJob(source: Self.partURL(bookID: book.id, index: part.index),
                 displayName: name, bookID: book.id, partIndex: part.index)
    }

    private func startJob(source: URL, displayName: String,
                          bookID: String? = nil, partIndex: Int? = nil) {
        // Work from an app-private copy so resume works even if the original
        // file is moved, renamed, or on a disconnected drive after a reboot.
        let id = UUID().uuidString
        let work = Self.jobDir(id).appendingPathComponent("document.pdf")
        try? FileManager.default.createDirectory(at: Self.jobDir(id), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: work) } catch {
            stage = .failed("Couldn't read the PDF file. Please choose it again.")
            return
        }
        guard let doc = PDFDocument(url: work), doc.pageCount > 0 else {
            try? FileManager.default.removeItem(at: Self.jobDir(id))
            stage = .failed("That file couldn't be opened as a PDF. Please choose it again.")
            return
        }
        previewDoc = doc
        pageCount = doc.pageCount
        activeState = SavedState(
            id: id, pdfPath: work.path, originalName: displayName,
            pageCount: pageCount, printer: selectedPrinter,
            quality: quality, blackAndWhite: blackAndWhite, paper: paper,
            reverseEvens: reverseEvens, rotateEvens: rotateEvens,
            pass: 1, sheetsCompleted: 0, awaitingFlip: false,
            jobID: nil, passRangeEnd: nil, updatedAt: Date(),
            printMode: printMode, bookID: bookID, partIndex: partIndex)
        saveState()
        pdfURL = work
        launchPass(pass: 1, offset: 0, tryAttach: false)
    }

    func continueAfterFlip() {
        activeState?.pass = 2
        activeState?.awaitingFlip = false
        activeState?.sheetsCompleted = 0
        activeState?.jobID = nil
        saveState()
        launchPass(pass: 2, offset: 0, tryAttach: false)
    }

    /// Resume a saved job from the list — after a quit, crash, reboot, or cancel.
    /// If the CUPS job is still alive we re-attach silently; otherwise the user
    /// confirms (and can correct) the exact page to continue from, with a preview.
    func resume(_ st: SavedState) {
        applyJob(st)
        if st.awaitingFlip {
            stage = .flip
            return
        }
        Task {
            if let jid = st.jobID {
                let q = await Self.sh("/usr/bin/lpstat", ["-o", st.printer])
                if q.out.contains(jid) {
                    // The live job's page counter starts where IT began, not where
                    // the pass began — use the offset recorded at submit time.
                    launchPass(pass: st.pass, offset: st.jobBaseSheets ?? st.sheetsCompleted, tryAttach: true)
                    return
                }
            }
            pendingJob = st
            pendingResumeSheet = min(st.sheetsCompleted + 1, confirmMaxSheet)
            stage = .confirmResume
        }
    }

    var confirmPass: Int { pendingJob?.pass ?? 1 }

    var confirmMaxSheet: Int {
        guard let st = pendingJob else { return 1 }
        if st.mode == .normal { return st.passRangeEnd ?? st.pageCount }
        if st.pass == 1, let end = st.passRangeEnd { return (end + 1) / 2 }
        return st.pass == 1 ? (st.pageCount + 1) / 2 : st.pageCount / 2
    }

    func docPageForSheet(_ sheet: Int, pass: Int) -> Int {
        if printMode == .normal { return sheet }
        return pass == 2 ? 2 * sheet : 2 * sheet - 1
    }

    func previewImage(docPage: Int) -> NSImage? {
        guard let doc = previewDoc, docPage >= 1, docPage <= doc.pageCount,
              let page = doc.page(at: docPage - 1) else { return nil }
        return page.thumbnail(of: CGSize(width: 1200, height: 1680), for: .mediaBox)
    }

    /// User confirmed (possibly adjusted) the next sheet — print from there.
    func confirmResume() {
        guard let st = pendingJob else { return }
        activeState?.sheetsCompleted = pendingResumeSheet - 1
        saveState()
        pendingJob = nil
        launchPass(pass: st.pass, offset: pendingResumeSheet - 1, tryAttach: false)
    }

    /// Reprint a saved job from the very beginning (side one, sheet one).
    func startFresh(_ st: SavedState) {
        var s = st
        s.pass = 1
        s.sheetsCompleted = 0
        s.awaitingFlip = false
        s.jobID = nil
        applyJob(s)
        saveState()
        launchPass(pass: 1, offset: 0, tryAttach: false)
    }

    private func applyJob(_ st: SavedState) {
        printMode = st.mode
        quality = st.quality
        blackAndWhite = st.blackAndWhite
        paper = st.paper
        reverseEvens = st.reverseEvens
        rotateEvens = st.rotateEvens
        if printers.contains(st.printer) { selectedPrinter = st.printer }
        pdfURL = URL(fileURLWithPath: st.pdfPath)
        pageCount = st.pageCount
        previewDoc = PDFDocument(url: URL(fileURLWithPath: st.pdfPath))
        activeState = st
    }

    private func launchPass(pass: Int, offset: Int, tryAttach: Bool) {
        passIsEven = pass == 2
        passFilteredOffset = offset
        progressDone = offset
        progressCurrent = nil
        runToken += 1
        let token = runToken
        startKeepAwake()
        Task {
            stage = .printing(pass: pass)
            statusLine = offset > 0 ? "Resuming from sheet \(offset + 1)…" : "Sending to the printer…"
            // If the interrupted CUPS job is still alive (queues survive reboots),
            // re-attach and watch it instead of submitting a duplicate.
            var attached = false
            if tryAttach, let jid = activeState?.jobID {
                let q = await Self.sh("/usr/bin/lpstat", ["-o", selectedPrinter])
                if q.out.contains(jid) {
                    currentJobID = jid
                    attached = true
                }
            }
            if !attached {
                let next = offset + 1
                let docPage = docPageForSheet(next, pass: pass)
                guard await submit(evenPass: passIsEven, fromDocPage: docPage) else { stopKeepAwake(); return }
            }
            await waitForDrain(token: token)
            finishPass(token: token)
        }
    }

    private func finishPass(token: Int) {
        guard token == runToken else { return }
        if case .failed = stage { return }
        if printMode == .duplex && !passIsEven && pageCount >= 2 {
            activeState?.awaitingFlip = true
            activeState?.jobID = nil
            saveState()
            stage = .flip
        } else {
            stopKeepAwake()
            clearState()   // both sides done — only now is the job removed
            stage = .done
        }
    }

    /// Stops printing but KEEPS the job in the list so it can be resumed later.
    func cancelPrinting() {
        runToken += 1
        stopKeepAwake()
        activeState?.jobID = nil
        saveState()
        activeState = nil
        Task {
            _ = await Self.sh("/usr/bin/cancel", ["-a", selectedPrinter])
            stage = .setup
        }
    }

    func resetToSetup() {
        runToken += 1
        stopKeepAwake()
        activeState = nil
        stage = .setup
    }

    private func submit(evenPass: Bool, fromDocPage: Int? = nil) async -> Bool {
        guard let url = pdfURL else { return false }
        var args = ["-d", selectedPrinter] + jobOptions(evenPass: evenPass)
        if let from = fromDocPage, from > 1 {
            let end = (!evenPass ? activeState?.passRangeEnd : nil) ?? pageCount
            args += ["-o", "page-ranges=\(from)-\(end)"]
        }
        args += [url.path]
        let r = await Self.sh("/usr/bin/lp", args)
        guard r.code == 0 else {
            stage = .failed("The document couldn't be sent to the printer.\n\n\(r.out)")
            return false
        }
        currentJobID = nil
        if let range = r.out.range(of: "request id is ") {
            currentJobID = r.out[range.upperBound...].split(separator: " ").first.map(String.init)
        }
        activeState?.jobID = currentJobID
        activeState?.jobBaseSheets = passFilteredOffset
        saveState()
        return true
    }

    private struct QueueSnapshot {
        var page: Int?          // current sheet within the running (filtered) job
        var reasons: String     // IPP printer-state-reasons line
        var jobQueued: Bool
        var disabled: Bool
    }

    nonisolated private static func firstTwoInts(_ pattern: String, _ text: String) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let a = Int(text[r1]), let b = Int(text[r2]) else { return nil }
        return (a, b)
    }

    private func snapshot() async -> QueueSnapshot {
        let ipp = await Self.sh("/usr/bin/ipptool",
                                ["-tv", "ipp://localhost/printers/\(selectedPrinter)", "get-printer-attributes.test"])
        var page: Int?
        // The Epson driver reports negative totals on ranged jobs ("Page 9 of -22"),
        // so the total group must accept a minus sign or progress is never parsed.
        if let (p, _) = Self.firstTwoInts(#"Page (\d+) of (-?\d+)"#, ipp.out) { page = p }
        var reasons = ""
        for line in ipp.out.split(separator: "\n") where line.contains("printer-state-reasons") {
            reasons = String(line)
        }
        let q = await Self.sh("/usr/bin/lpstat", ["-o", selectedPrinter])
        let jobsText = q.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let queued = currentJobID.map { jobsText.contains($0) } ?? !jobsText.isEmpty
        let p = await Self.sh("/usr/bin/lpstat", ["-p", selectedPrinter])
        return QueueSnapshot(page: page, reasons: reasons, jobQueued: queued, disabled: p.out.contains("disabled"))
    }

    private func failHard(_ message: String) async {
        _ = await Self.sh("/usr/bin/cancel", ["-a", selectedPrinter])
        stopKeepAwake()
        stage = .failed(message)
    }

    // A condition the user can fix at the printer: the job is NOT lost — the
    // printer continues by itself once fixed. Never cancel, never time out.
    nonisolated private static func userFixable(_ reasons: String) -> Bool {
        ["media-empty", "media-jam", "cover-open", "door-open",
         "input-tray-missing", "marker-supply", "media-needed"]
            .contains { reasons.contains($0) }
    }

    // The data link to the printer is gone; a half-sent job cannot continue and
    // must be cancelled and resubmitted from the last completed sheet.
    nonisolated private static func connectionBroken(_ reasons: String) -> Bool {
        ["offline", "connecting-to-device", "com.epson.COM", "timed-out"]
            .contains { reasons.contains($0) }
    }

    nonisolated private static func friendlyProblem(_ reasons: String) -> String {
        if reasons.contains("media-empty") || reasons.contains("media-needed") {
            return "Out of paper — load A4 into the rear tray, keeping any half-printed stack in order. Printing continues by itself (press the blinking paper button if there is one)."
        }
        if reasons.contains("media-jam") {
            return "Paper jam — gently pull out the stuck sheet, then press the paper button on the printer. Printing will continue."
        }
        if reasons.contains("cover-open") || reasons.contains("door-open") {
            return "The printer's cover is open — please close it. Printing will continue."
        }
        if reasons.contains("marker-supply") {
            return "The printer reports an ink problem — check the ink tanks."
        }
        return "The printer needs attention. Printing will continue once it's fixed."
    }

    var totalSheetsThisPass: Int {
        if printMode == .normal { return pageCount }
        return passIsEven ? pageCount / 2 : (pageCount + 1) / 2
    }

    private func recordProgress(sheetsDone: Int) {
        if activeState != nil && activeState!.sheetsCompleted != sheetsDone {
            activeState!.sheetsCompleted = sheetsDone
            saveState()
        }
    }

    private func waitForDrain(token: Int) async {
        var recoveries = 0
        var lastPage = 0
        var lastAdvance = Date()

        while token == runToken {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard token == runToken else { return }

            let s = await snapshot()

            if s.disabled {
                // Queue paused itself (e.g. send failure) — just re-enable; the
                // stall watchdog below handles the case where that never helps.
                _ = await Self.sh("/usr/sbin/cupsenable", [selectedPrinter])
            }

            if !s.jobQueued { return }   // pass finished

            if let p = s.page, p > lastPage {
                lastPage = p
                lastAdvance = Date()
                recoveries = 0           // real progress resets the failure budget
            }
            // Sheet N is *printing*; only N-1 are safely done.
            recordProgress(sheetsDone: passFilteredOffset + max(lastPage - 1, 0))
            progressDone = passFilteredOffset + max(lastPage - 1, 0)
            progressCurrent = lastPage > 0 ? passFilteredOffset + lastPage : nil

            // 1) Conditions the user fixes at the printer (paper out, jam, open
            //    cover): show instructions and wait as long as it takes.
            if Self.userFixable(s.reasons) {
                statusLine = Self.friendlyProblem(s.reasons)
                lastAdvance = Date()
                continue
            }

            let broken = Self.connectionBroken(s.reasons)
            if broken {
                statusLine = "Lost contact with the printer — check its power and USB cable. I'll carry on automatically once it's back."
            } else if lastPage > 0 {
                statusLine = "Printing sheet \(passFilteredOffset + lastPage) of \(totalSheetsThisPass)…"
            }

            // 2) Connection loss or a wedged driver: the half-sent job is dead.
            //    Cancel it, wait for the printer to come back (however long that
            //    takes — power-cycle, replug, reboot), resume from the last sheet.
            let stalledFor = Date().timeIntervalSince(lastAdvance)
            let commError = s.reasons.contains("-error") || broken
            if (commError && stalledFor > 60) || stalledFor > 420 {
                recoveries += 1
                if recoveries > 8 {
                    await failHard("The printer keeps dropping its connection — this points to a loose or faulty USB cable. Plug it directly into the Mac (no hub) or swap the cable, then reopen DuplexPrint: your progress is saved and it will offer to resume exactly where it stopped.")
                    return
                }
                if let id = currentJobID {
                    _ = await Self.sh("/usr/bin/cancel", [id])
                } else {
                    _ = await Self.sh("/usr/bin/cancel", ["-a", selectedPrinter])
                }
                statusLine = "Connection lost — waiting for the printer to come back…"

                // Wait (up to 30 min per incident) for the link to recover.
                var waited = 0
                while token == runToken && waited < 1800 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    waited += 5
                    let s2 = await snapshot()
                    if !Self.connectionBroken(s2.reasons) && !s2.reasons.contains("-error") { break }
                }
                guard token == runToken else { return }

                statusLine = "Printer is back — resuming from sheet \(passFilteredOffset + max(lastPage, 1))…"
                _ = await Self.sh("/usr/sbin/cupsenable", [selectedPrinter])
                // Re-print the sheet that was in flight (it may be incomplete).
                passFilteredOffset += max(lastPage, 1) - 1
                let next = passFilteredOffset + 1
                let docPage = docPageForSheet(next, pass: passIsEven ? 2 : 1)
                guard await submit(evenPass: passIsEven, fromDocPage: docPage) else { return }
                lastPage = 0
                lastAdvance = Date()
            }
        }
    }

    /// --screenshots harness only: pose the printing screen with fake progress.
    func demoPose(previewDoc doc: PDFDocument?, done: Int, current: Int?, status: String) {
        previewDoc = doc
        progressDone = done
        progressCurrent = current
        statusLine = status
    }

    // MARK: Test document

    func useTestDocument() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DuplexPrint-Test.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 in points
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for i in 1...4 {
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 56)]
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20)]
            let side = i % 2 == 1 ? "FRONT of sheet \((i + 1) / 2)" : "BACK of sheet \(i / 2)"
            NSAttributedString(string: "▲ this edge is the TOP ▲", attributes: small)
                .draw(at: NSPoint(x: 170, y: 790))
            NSAttributedString(string: "Page \(i)", attributes: big)
                .draw(at: NSPoint(x: 190, y: 450))
            NSAttributedString(string: side, attributes: small)
                .draw(at: NSPoint(x: 200, y: 400))
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        }
        ctx.closePDF()
        setDocument(url)
    }
}

// MARK: - Screenshot harness (--screenshots <dir>; renders views offscreen)

enum ScreenshotMaker {
    @MainActor static func run(outDir: String) {
        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // A friendly demo document.
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("LinearAlgebra.pdf")
        makeDemoPDF(at: pdfURL, pages: 12)
        let doc = PDFDocument(url: pdfURL)

        let c = PrintController()
        c.printers = ["EPSON_L130_Series_2"]
        c.selectedPrinter = "EPSON_L130_Series_2"
        c.isEpson = true
        c.printMode = .duplex
        c.quality = "Normal"
        c.setDocument(pdfURL)

        let book = Book(id: "demo", originalName: "LinearAlgebra.pdf", pageCount: 242,
                        printMode: .duplex,
                        parts: [BookPart(index: 1, startPage: 1, endPage: 82, printed: true),
                                BookPart(index: 2, startPage: 83, endPage: 164, printed: false),
                                BookPart(index: 3, startPage: 165, endPage: 242, printed: false)],
                        createdAt: Date(), isExtraction: false)
        c.books = [book]

        UserDefaults.standard.set(200.0, forKey: "thumbHeight")

        // The book page loads part PDFs from their real paths — stage them.
        let demoDir = PrintController.bookDir("demo")
        try? FileManager.default.createDirectory(at: demoDir, withIntermediateDirectories: true)
        for i in 1...3 {
            try? FileManager.default.copyItem(at: pdfURL,
                                              to: PrintController.partURL(bookID: "demo", index: i))
        }
        defer { try? FileManager.default.removeItem(at: demoDir) }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)   // no Dock icon, no focus steal

        save(SetupView(), c, width: 620, height: nil, name: "main-screen", to: out)
        save(SplitView(demoDoc: doc, demoStarts: [1, 5, 9], demoPartCount: 3),
             c, width: 820, height: 980, name: "split-screen", to: out)
        save(BookDetailView(bookID: "demo"), c, width: 820, height: 900, name: "book-page", to: out)
        save(PrintPartSheet(book: book, part: book.parts[1], onConfirm: {}, onCancel: {}),
             c, width: 560, height: nil, name: "print-confirm", to: out)
        c.demoPose(previewDoc: doc, done: 3, current: 4, status: "Printing sheet 4 of 6…")
        save(PrintingView(pass: 1), c, width: 620, height: 760, name: "printing", to: out)
        save(FlipView(), c, width: 620, height: nil, name: "flip", to: out)
    }

    /// Renders the view in a real (never-shown) window so AppKit-backed
    /// controls draw properly, then captures the view hierarchy at 2×.
    @MainActor private static func save<V: View>(_ view: V, _ c: PrintController,
                                                 width: CGFloat, height: CGFloat?,
                                                 name: String, to out: URL) {
        let root = AnyView(
            view.environmentObject(c)
                .padding(24)
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let host = NSHostingView(rootView: root)
        let h = height ?? 10   // grow to fit below when no height given
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: h),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: h)
        host.layoutSubtreeIfNeeded()
        if height == nil {
            let fit = host.fittingSize
            win.setContentSize(NSSize(width: width, height: max(fit.height, 10)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: max(fit.height, 10))
            host.layoutSubtreeIfNeeded()
        }
        // Let SwiftUI settle (thumbnails, AppStorage, async body updates).
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let b = host.bounds
        guard b.width > 0, b.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            print("FAIL  \(name)")
            return
        }
        rep.size = b.size
        host.cacheDisplay(in: b, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL  \(name)")
            return
        }
        try? png.write(to: out.appendingPathComponent("\(name).png"))
        print("wrote \(name).png")
        win.close()
    }

    /// A 12-page PDF that looks like a real book in thumbnails.
    private static func makeDemoPDF(at url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current = ns
            NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.6, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 802, width: 595, height: 40)).fill()
            NSAttributedString(string: "Linear Algebra — demo",
                               attributes: [.font: NSFont.boldSystemFont(ofSize: 16),
                                            .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: 40, y: 813))
            NSAttributedString(string: "Chapter \((i + 3) / 4)",
                               attributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
                .draw(at: NSPoint(x: 40, y: 740))
            for line in 0..<14 {
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: NSRect(x: 40, y: 680 - line * 40,
                                          width: line % 4 == 3 ? 340 : 515, height: 12)).fill()
            }
            NSAttributedString(string: "\(i)",
                               attributes: [.font: NSFont.systemFont(ofSize: 14),
                                            .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: NSPoint(x: 288, y: 30))
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        Group {
            switch c.stage {
            case .setup: SetupView()
            case .split: SplitView()
            case .book(let id): BookDetailView(bookID: id)
            case .confirmResume: ConfirmResumeView()
            case .printing(let pass): PrintingView(pass: pass)
            case .flip: FlipView()
            case .done: DoneView()
            case .failed(let msg): FailedView(message: msg)
            }
        }
        .padding(24)
        .task {
            await c.refreshPrinters()
            c.loadJobs()
            c.loadBooks()
            await c.autoAttachIfPrinting()
        }
    }
}

// MARK: - Setup screen

struct SetupView: View {
    @EnvironmentObject var c: PrintController
    @State private var showPicker = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("DuplexPrint").font(.largeTitle.bold())
                Text("Print on both sides of the paper — with just one flip.")
                    .foregroundStyle(.secondary)
            }

            JobsListSection()
            BooksSection()

            // Drop zone
            VStack(spacing: 8) {
                Image(systemName: c.pdfURL == nil ? "doc.badge.plus" : "doc.richtext")
                    .font(.system(size: 40))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                if let url = c.pdfURL {
                    Text(url.lastPathComponent).font(.headline)
                    Text("\(c.pageCount) pages  →  \(c.sheetCount) sheets of paper")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drop your PDF here").font(.headline)
                    Text("or").foregroundStyle(.secondary)
                }
                Button(c.pdfURL == nil ? "Choose a PDF…" : "Choose a different PDF…") {
                    showPicker = true
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in c.setDocument(url) } }
                }
                return true
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { c.setDocument(url) }
            }

            if c.pdfURL != nil && c.pageCount >= 2 {
                Button {
                    c.enterSplit()
                } label: {
                    Label("Split this PDF or pick pages…", systemImage: "square.split.2x1")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }

            // Settings — chosen once, used for both sides
            GroupBox("Print settings") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Printing", selection: $c.printMode) {
                        Text("Two-sided (flip once)").tag(PrintMode.duplex)
                        Text("Normal (one side per sheet)").tag(PrintMode.normal)
                    }
                    .pickerStyle(.segmented)
                    Picker("Printer", selection: $c.selectedPrinter) {
                        ForEach(c.printers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")) }
                    }
                    Picker("Paper size", selection: $c.paper) {
                        ForEach(c.papers, id: \.self) { Text($0) }
                    }
                    Picker("Quality", selection: $c.quality) {
                        ForEach(c.qualities, id: \.self) { Text($0) }
                    }
                    Text("Same ladder as Epson's own dialog — Fast Economy is quickest and lightest on ink, Best is slowest and darkest. Normal suits most documents.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Colour", selection: $c.blackAndWhite) {
                        Text("Colour").tag(false)
                        Text("Black & White").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(8)
            }

            DisclosureGroup("Advanced (only if pages come out mismatched)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Print the second side in reverse order", isOn: $c.reverseEvens)
                        .disabled(c.printMode == .normal)
                    Toggle("Rotate the second side 180°", isOn: $c.rotateEvens)
                        .disabled(c.printMode == .normal)
                    if c.printMode == .normal {
                        Text("These two switches only matter for two-sided printing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use a 4-page test document") { c.useTestDocument() }
                    Text("Tip: print the 4-page test first. If the backs come out on the wrong sheets or upside down, adjust the two switches above — DuplexPrint remembers them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            if c.sheetCount > 30 {
                Label("Your printer's output tray holds about 30 sheets. This document uses \(c.sheetCount) — collect the printed pages as they pile up, keeping them in order.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if c.pdfURL != nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if c.printMode == .normal {
                            Label("The printer prints all \(c.pageCount) page\(c.pageCount == 1 ? "" : "s") in one go, one page per sheet — no flipping needed.",
                                  systemImage: "printer")
                        } else if c.pageCount < 2 {
                            Label("This document has a single page — it prints in one go, no flipping needed.",
                                  systemImage: "1.circle")
                        } else {
                            Label("The printer first prints the FRONTS: odd pages 1, 3, 5… (\(c.sheetCount) sheets).",
                                  systemImage: "1.circle")
                            Label("Then it stops and shows you how to flip the printed stack and put it back in. Take your time — nothing happens until you confirm.",
                                  systemImage: "2.circle")
                            Label("After you confirm, it prints the BACKS: even pages 2, 4, 6… Same settings, nothing to configure.",
                                  systemImage: "3.circle")
                        }
                    }
                    .font(.callout)
                    .padding(6)
                } label: {
                    Label("What will happen when you press Print", systemImage: "info.circle")
                }
            }

            Button {
                c.startPrinting()
            } label: {
                Label("Print", systemImage: "printer.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(c.pdfURL == nil || c.selectedPrinter.isEmpty)
        }
    }
}

// MARK: - Shared PDF page thumbnails

struct PDFThumb: View {
    let doc: PDFDocument?
    let page: Int          // 1-based, in the given document
    let height: CGFloat

    var body: some View {
        // Render at 2× and scale down, or thumbnails come out blurry on Retina.
        if let img = doc?.page(at: page - 1)?
            .thumbnail(of: CGSize(width: height * 1.5, height: height * 2), for: .mediaBox) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .border(Color.secondary.opacity(0.4), width: 1)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: height * 0.72, height: height)
        }
    }
}

/// Full-size page viewer, opened by clicking any thumbnail. Browse with the
/// on-screen arrows or the ← → keys.
struct PageZoomView: View {
    let doc: PDFDocument?
    let pages: [Int]       // 1-based page numbers in the given document
    let labels: [Int]      // number shown in the title (original numbering)
    let startIndex: Int
    let onClose: () -> Void
    @State private var i = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Page \(labels.indices.contains(i) ? labels[i] : i + 1)  ·  \(i + 1) of \(pages.count) shown")
                .font(.headline)
            if pages.indices.contains(i),
               let img = doc?.page(at: pages[i] - 1)?
                .thumbnail(of: CGSize(width: 1400, height: 1960), for: .mediaBox) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.secondary.opacity(0.4), width: 1)
                    .shadow(radius: 3)
            } else {
                Text("(couldn't render this page)").foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button {
                    i = max(0, i - 1)
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(i == 0)

                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.escape, modifiers: [])

                Button {
                    i = min(pages.count - 1, i + 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(i == pages.count - 1)
            }
        }
        .padding(16)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 700, idealHeight: 800)
        .onAppear { i = min(max(startIndex, 0), max(pages.count - 1, 0)) }
    }
}

/// One shared, remembered preview size for every page grid in the app.
struct ThumbSizeSlider: View {
    @AppStorage("thumbHeight") private var thumbHeight = 260.0

    var body: some View {
        HStack(spacing: 8) {
            Text("Preview size").font(.caption).foregroundStyle(.secondary)
            Image(systemName: "doc").imageScale(.small).foregroundStyle(.secondary)
            Slider(value: $thumbHeight, in: 140...480, step: 40)
                .frame(width: 180)
            Image(systemName: "doc").imageScale(.large).foregroundStyle(.secondary)
        }
        .help("How big the page previews are — drag right to make them readable")
    }
}

/// "What's inside" — a grid of page thumbnails with numbers underneath.
/// Click any page to see it full size; the slider above sets the grid size.
struct PagesGrid: View {
    let doc: PDFDocument?
    let pages: [Int]       // 1-based page numbers in the given document
    let labels: [Int]      // number shown under each thumb (original numbering)
    @AppStorage("thumbHeight") private var thumbHeight = 260.0
    @State private var zoomIndex: Int?

    var body: some View {
        let h = CGFloat(thumbHeight)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: h * 0.72 + 12), spacing: 10)], spacing: 12) {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                Button {
                    zoomIndex = i
                } label: {
                    VStack(spacing: 3) {
                        PDFThumb(doc: doc, page: p, height: h)
                        Text("\(labels.indices.contains(i) ? labels[i] : p)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to see this page full size")
            }
        }
        .padding(.top, 6)
        .sheet(isPresented: Binding(get: { zoomIndex != nil },
                                    set: { if !$0 { zoomIndex = nil } })) {
            PageZoomView(doc: doc, pages: pages, labels: labels,
                         startIndex: zoomIndex ?? 0) { zoomIndex = nil }
        }
    }
}

// MARK: - Split screen (check every part before anything is saved)

struct SplitView: View {
    @EnvironmentObject var c: PrintController
    @State private var doc: PDFDocument?
    @State private var mode = 0                 // 0 = equal parts, 1 = pick pages
    @State private var partCount = 2
    @State private var starts: [Int] = [1]      // first page of each part
    @State private var extractSpec = ""
    @State private var cardZoom: Int?           // document page opened full size
    @AppStorage("thumbHeight") private var thumbHeight = 260.0

    // Extra parameters exist only for the --screenshots harness, which renders
    // this view offscreen where onAppear never fires. Real callers use SplitView().
    init(demoDoc: PDFDocument? = nil, demoStarts: [Int]? = nil, demoPartCount: Int = 2) {
        _doc = State(initialValue: demoDoc)
        _starts = State(initialValue: demoStarts ?? [1])
        _partCount = State(initialValue: demoPartCount)
    }

    private var step: Int { c.printMode == .duplex ? 2 : 1 }
    private var maxParts: Int { max(2, min(12, c.printMode == .duplex ? c.sheetCount : c.pageCount)) }
    // Guarded: while a finished split clears the loaded document, SwiftUI can
    // re-evaluate this view with pageCount == 0 and stale starts — an invalid
    // range (e.g. 145...0) would trap. Render nothing instead.
    private var ranges: [(start: Int, end: Int)] {
        guard c.pageCount > 0, let last = starts.last, last <= c.pageCount,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return [] }
        return starts.enumerated().map { i, s in (s, i + 1 < starts.count ? starts[i + 1] - 1 : c.pageCount) }
    }
    private var extractPages: [Int]? { PrintController.parseRanges(extractSpec, pageCount: c.pageCount) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Split this PDF").font(.title.bold())
                Text("\(c.pdfURL?.lastPathComponent ?? "") · \(c.pageCount) pages — check the parts below. Nothing is saved until you press the blue button.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Picker("", selection: $mode) {
                    Text("Equal parts").tag(0)
                    Text("Just some pages").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                ThumbSizeSlider()
            }

            if mode == 0 { equalParts } else { pickPages }

            if c.isSplitting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building the PDFs…").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Button("Back") { c.stage = .setup }
                if mode == 0 {
                    Button {
                        c.splitLoadedDocument(atStarts: starts)
                    } label: {
                        Label("Split into these \(starts.count) parts", systemImage: "square.split.2x1")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(c.isSplitting || starts.count < 2)
                } else {
                    Button {
                        c.extractPages(extractSpec)
                    } label: {
                        Label("Make a PDF of these pages", systemImage: "doc.on.doc")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(c.isSplitting || (extractPages?.isEmpty ?? true))
                }
            }
        }
        .onAppear {
            doc = c.pdfURL.flatMap { PDFDocument(url: $0) }
            resetStarts()
        }
        .sheet(isPresented: Binding(get: { cardZoom != nil },
                                    set: { if !$0 { cardZoom = nil } })) {
            let all = Array(1...max(c.pageCount, 1))
            PageZoomView(doc: doc, pages: all, labels: all,
                         startIndex: (cardZoom ?? 1) - 1) { cardZoom = nil }
        }
    }

    private var equalParts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Split into \(partCount) parts", value: $partCount, in: 2...maxParts)
                .onChange(of: partCount) { _ in resetStarts() }
            Text(c.printMode == .duplex
                 ? "Every part starts on a fresh sheet, so the arrows move a boundary two pages at a time. Changing the number of parts resets the boundaries."
                 : "Use the arrows on a part to move its starting page. Changing the number of parts resets the boundaries.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ranges.indices, id: \.self) { i in
                        partCard(i)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func partCard(_ i: Int) -> some View {
        let r = ranges[i]
        let n = r.end - r.start + 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Part \(i + 1)").font(.headline)
                    Text("pages \(r.start)–\(r.end) · \(n) pages · \(c.printMode == .duplex ? (n + 1) / 2 : n) sheets")
                        .font(.caption).foregroundStyle(.secondary)
                    if i > 0 {
                        HStack(spacing: 6) {
                            Button { move(i, -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(starts[i] - step < bounds(i).lowerBound)
                            Text("starts at page \(r.start)")
                                .font(.callout.monospacedDigit())
                            Button { move(i, +1) } label: { Image(systemName: "chevron.right") }
                                .disabled(starts[i] + step > bounds(i).upperBound)
                        }
                    } else {
                        Text("starts at page 1").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    cardZoom = r.start
                } label: {
                    VStack(spacing: 3) {
                        PDFThumb(doc: doc, page: r.start, height: CGFloat(thumbHeight))
                        Text("first page (\(r.start))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to see this page full size")
                Button {
                    cardZoom = r.end
                } label: {
                    VStack(spacing: 3) {
                        PDFThumb(doc: doc, page: r.end, height: CGFloat(thumbHeight))
                        Text("last page (\(r.end))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to see this page full size")
            }
            DisclosureGroup("See all \(n) pages") {
                PagesGrid(doc: doc, pages: Array(r.start...r.end), labels: Array(r.start...r.end))
            }
            .font(.callout)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var pickPages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type the pages you want, in the order you want them:")
            TextField("e.g. 5-20, 35, 40-42", text: $extractSpec)
                .textFieldStyle(.roundedBorder)
            Text(extractCaption)
                .font(.caption)
                .foregroundStyle(extractSpec.isEmpty || extractPages != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            if let pages = extractPages, !pages.isEmpty {
                ScrollView {
                    PagesGrid(doc: doc, pages: pages, labels: pages)
                }
            } else {
                Spacer()
            }
        }
    }

    private var extractCaption: String {
        if extractSpec.isEmpty {
            return "Type page numbers like 5-20, 35, 40-42 — the new PDF keeps them in the order you type."
        }
        guard let pages = extractPages else {
            return "I couldn't read that — use page numbers like 5-20, 35, 40-42 (this document has \(c.pageCount) pages)."
        }
        let sheets = c.printMode == .duplex ? (pages.count + 1) / 2 : pages.count
        return "\(pages.count) page\(pages.count == 1 ? "" : "s") → \(sheets) sheet\(sheets == 1 ? "" : "s") of paper. Every page is shown below — check them before you press the button."
    }

    // Boundaries: a part's start must stay past the previous part's start and
    // before the next one's; in duplex mode starts also stay ODD so every part
    // begins on a fresh sheet.
    private func bounds(_ i: Int) -> ClosedRange<Int> {
        let lower = starts[i - 1] + step
        var upper = i + 1 < starts.count ? starts[i + 1] - step : c.pageCount
        if step == 2 && upper % 2 == 0 { upper -= 1 }
        return lower...max(lower, upper)
    }

    private func move(_ i: Int, _ dir: Int) {
        let b = bounds(i)
        starts[i] = min(max(starts[i] + dir * step, b.lowerBound), b.upperBound)
    }

    private func resetStarts() {
        let sizes = PrintController.partSizes(pages: c.pageCount, parts: partCount, mode: c.printMode)
        var acc = 1
        starts = sizes.map { size in defer { acc += size }; return acc }
        if sizes.count != partCount { partCount = max(2, sizes.count) }
    }
}

// MARK: - Books list (compact rows on the main screen — open for details)

struct BooksSection: View {
    @EnvironmentObject var c: PrintController
    @State private var bookToDelete: Book?

    var body: some View {
        if !c.books.isEmpty {
            GroupBox {
                VStack(spacing: 10) {
                    ForEach(c.books) { book in
                        HStack(spacing: 10) {
                            Image(systemName: book.isExtraction == true ? "doc.on.doc" : "books.vertical")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.originalName).font(.headline).lineLimit(1)
                                Text(caption(book)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { c.stage = .book(book.id) }
                            Menu {
                                Button("Delete this book and its parts", role: .destructive) { bookToDelete = book }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                }
                .padding(6)
            } label: {
                Label("Split documents", systemImage: "books.vertical")
            }
            .alert("Delete \(bookToDelete?.originalName ?? "this book")?",
                   isPresented: Binding(get: { bookToDelete != nil },
                                        set: { if !$0 { bookToDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let b = bookToDelete { c.deleteBook(b) }
                    bookToDelete = nil
                }
                Button("Cancel", role: .cancel) { bookToDelete = nil }
            } message: {
                Text("This removes its saved part PDFs and any unfinished printing for its parts. The original PDF on your Mac is not touched.")
            }
        }
    }

    private func caption(_ book: Book) -> String {
        if book.isExtraction == true, let p = book.parts.first {
            return "\(p.pageRangeLabel) · \(p.printed ? "printed" : "not printed yet")"
        }
        return "\(book.parts.count) parts · \(book.printedCount) of \(book.parts.count) printed"
    }
}

// MARK: - Print-a-part confirmation (check every setting before it starts)

struct PrintPartSheet: View {
    @EnvironmentObject var c: PrintController
    let book: Book
    let part: BookPart
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var sheets: Int { c.printMode == .duplex ? (part.size + 1) / 2 : part.size }

    var body: some View {
        VStack(spacing: 14) {
            Text(book.isExtraction == true ? "Print the extracted pages?" : "Print Part \(part.index) of \(book.parts.count)?")
                .font(.title2.bold())
            Text("\(book.originalName) · \(part.pageRangeLabel) · \(part.size) pages → \(sheets) sheet\(sheets == 1 ? "" : "s") of paper")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GroupBox("Check the print settings") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Printing", selection: $c.printMode) {
                        Text("Two-sided (flip once)").tag(PrintMode.duplex)
                        Text("Normal (one side per sheet)").tag(PrintMode.normal)
                    }
                    .pickerStyle(.segmented)
                    if c.printMode == .duplex && part.size % 2 == 1 {
                        Text("This part has an odd number of pages — the last sheet's back will stay blank.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Printer", selection: $c.selectedPrinter) {
                        ForEach(c.printers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")) }
                    }
                    Picker("Paper size", selection: $c.paper) {
                        ForEach(c.papers, id: \.self) { Text($0) }
                    }
                    Picker("Quality", selection: $c.quality) {
                        ForEach(c.qualities, id: \.self) { Text($0) }
                    }
                    Picker("Colour", selection: $c.blackAndWhite) {
                        Text("Colour").tag(false)
                        Text("Black & White").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(8)
            }

            HStack(spacing: 14) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button {
                    onConfirm()
                } label: {
                    Label("Print with these settings", systemImage: "printer.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(c.selectedPrinter.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear {
            // The book's boundaries were planned for this mode — offer it as
            // the default; the user can still change everything here.
            c.printMode = book.printMode
        }
    }
}

// MARK: - Book detail page (print each part from here)

struct BookDetailView: View {
    @EnvironmentObject var c: PrintController
    let bookID: String
    @State private var partDocs: [Int: PDFDocument] = [:]
    @State private var confirmDelete = false
    @State private var zoomPart: Int?           // part whose first page is opened full size
    @State private var partToPrint: BookPart?   // part awaiting settings confirmation
    @AppStorage("thumbHeight") private var thumbHeight = 260.0

    // demoDocs exists only for the --screenshots harness (onAppear never fires
    // offscreen); real callers use BookDetailView(bookID:).
    init(bookID: String, demoDocs: [Int: PDFDocument] = [:]) {
        self.bookID = bookID
        _partDocs = State(initialValue: demoDocs)
    }

    var body: some View {
        if let book = c.books.first(where: { $0.id == bookID }) {
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text(book.originalName).font(.title.bold()).lineLimit(1)
                    Text(subtitle(book)).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    ThumbSizeSlider()
                }
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(book.parts, id: \.index) { part in
                            partCard(book, part)
                        }
                    }
                }
                .sheet(isPresented: Binding(get: { partToPrint != nil },
                                            set: { if !$0 { partToPrint = nil } })) {
                    if let part = partToPrint {
                        PrintPartSheet(book: book, part: part,
                                       onConfirm: {
                                           partToPrint = nil
                                           c.printPart(book, part)
                                       },
                                       onCancel: { partToPrint = nil })
                    }
                }
                HStack {
                    Button("Back to the main screen") { c.resetToSetup() }
                    Spacer()
                    Button("Delete this book…", role: .destructive) { confirmDelete = true }
                }
            }
            .onAppear { loadDocs(book) }
            .sheet(isPresented: Binding(get: { zoomPart != nil },
                                        set: { if !$0 { zoomPart = nil } })) {
                if let pi = zoomPart, let part = book.parts.first(where: { $0.index == pi }) {
                    let doc = partDocs[pi]
                    let n = doc?.pageCount ?? part.size
                    let labels = part.pages == nil && n == part.size
                        ? Array(part.startPage...part.endPage)
                        : Array(1...n)
                    PageZoomView(doc: doc, pages: Array(1...n), labels: labels,
                                 startIndex: 0) { zoomPart = nil }
                }
            }
            .alert("Delete \(book.originalName)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    c.deleteBook(book)
                    c.resetToSetup()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes its saved part PDFs and any unfinished printing for its parts. The original PDF on your Mac is not touched.")
            }
        } else {
            VStack(spacing: 16) {
                Text("This book has been deleted.").font(.title2.bold())
                Button("Back") { c.resetToSetup() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func loadDocs(_ book: Book) {
        for part in book.parts {
            partDocs[part.index] = PDFDocument(url: PrintController.partURL(bookID: book.id, index: part.index))
        }
    }

    private func subtitle(_ book: Book) -> String {
        if book.isExtraction == true { return "pages picked from a \(book.pageCount)-page PDF" }
        return "split into \(book.parts.count) parts · \(book.printedCount) of \(book.parts.count) printed"
    }

    @ViewBuilder
    private func partCard(_ book: Book, _ part: BookPart) -> some View {
        let status = c.status(of: part, in: book)
        let doc = partDocs[part.index]
        let n = doc?.pageCount ?? part.size
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    zoomPart = part.index
                } label: {
                    VStack(spacing: 3) {
                        PDFThumb(doc: doc, page: 1, height: CGFloat(thumbHeight))
                        Text("first page").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to look through this part full size")
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.isExtraction == true ? "Extracted pages" : "Part \(part.index) of \(book.parts.count)")
                        .font(.headline)
                    Text("\(part.pageRangeLabel) · \(part.size) page\(part.size == 1 ? "" : "s") · \(book.printMode == .duplex ? (part.size + 1) / 2 : part.size) sheets")
                        .font(.caption).foregroundStyle(.secondary)
                    statusLabel(status)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    switch status {
                    case .notPrinted:
                        Button {
                            partToPrint = part
                        } label: {
                            Label("Print", systemImage: "printer.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    case .inProgress(let job):
                        Button {
                            c.resume(job)
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    case .printed:
                        Button {
                            partToPrint = part
                        } label: {
                            Label("Print again", systemImage: "printer")
                        }
                    }
                    Menu {
                        Button("Save a copy…") { saveCopy(book, part) }
                        Button("Forget progress (mark as not printed)", role: .destructive) { c.resetPart(book, part) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            DisclosureGroup("See all \(n) pages") {
                let labels = part.pages == nil && n == part.size
                    ? Array(part.startPage...part.endPage)   // contiguous part: original numbering
                    : Array(1...n)                           // extraction: the new PDF's own numbering
                PagesGrid(doc: doc, pages: Array(1...n), labels: labels)
            }
            .font(.callout)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func statusLabel(_ s: PrintController.PartStatus) -> some View {
        switch s {
        case .notPrinted:
            Label("Not printed yet", systemImage: "circle")
                .font(.callout).foregroundStyle(.secondary)
        case .inProgress:
            Label("Printing was started — resume anytime", systemImage: "printer.fill")
                .font(.callout).foregroundStyle(Color.accentColor)
        case .printed:
            Label("Printed", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }

    private func saveCopy(_ book: Book, _ part: BookPart) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (book.originalName as NSString).deletingPathExtension
        panel.nameFieldStringValue = book.isExtraction == true
            ? "\(base) — \(part.pageRangeLabel).pdf"
            : "\(base) — Part \(part.index).pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(
                at: PrintController.partURL(bookID: book.id, index: part.index), to: dest)
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Unfinished jobs list

struct JobsListSection: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        if !c.jobs.isEmpty {
            GroupBox {
                VStack(spacing: 10) {
                    ForEach(c.jobs, id: \.id) { st in
                        HStack(spacing: 10) {
                            Image(systemName: st.awaitingFlip ? "arrow.triangle.2.circlepath" : "doc.richtext")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.originalName).font(.headline).lineLimit(1)
                                Text(statusText(st)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { c.resume(st) }
                                .buttonStyle(.borderedProminent)
                            Menu {
                                Button("Start over from the beginning") { c.startFresh(st) }
                                Button("Delete this job", role: .destructive) { c.deleteJob(st) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                }
                .padding(6)
            } label: {
                Label("Unfinished print jobs", systemImage: "tray.full")
            }
        }
    }

    private func statusText(_ st: SavedState) -> String {
        if st.awaitingFlip {
            return "First side done — flip the stack and resume"
        }
        let when = st.updatedAt.formatted(date: .abbreviated, time: .shortened)
        if st.mode == .normal {
            return "\(st.sheetsCompleted) of \(st.pageCount) pages printed · \(when)"
        }
        let total = st.pass == 1 ? (st.pageCount + 1) / 2 : st.pageCount / 2
        return "\(st.pass == 1 ? "First" : "Second") side: \(st.sheetsCompleted) of \(total) sheets printed · \(when)"
    }
}

// MARK: - Confirm-resume screen (preview + adjust the next page)

struct ConfirmResumeView: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        let pass = c.confirmPass
        let docPage = c.docPageForSheet(c.pendingResumeSheet, pass: pass)
        VStack(spacing: 14) {
            Text("Continue printing — from here?").font(.title2.bold())
            Text(c.printMode == .normal
                 ? "This is the next page that will come out of the printer."
                 : "This is the next page that will come out of the printer, on the \(pass == 1 ? "front" : "back") of sheet \(c.pendingResumeSheet).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(c.settingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let img = c.previewImage(docPage: docPage) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.secondary.opacity(0.4), width: 1)
                    .shadow(radius: 3)
            } else {
                Text("(couldn't render a preview of this page)")
                    .foregroundStyle(.secondary)
            }
            Text("Document page \(docPage) of \(c.pageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button {
                    c.pendingResumeSheet = max(1, c.pendingResumeSheet - 1)
                } label: { Label("Earlier page", systemImage: "chevron.left") }
                .disabled(c.pendingResumeSheet <= 1)

                Text("\(c.printMode == .normal ? "Page" : "Sheet") \(c.pendingResumeSheet) of \(c.confirmMaxSheet)")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 110)

                Button {
                    c.pendingResumeSheet = min(c.confirmMaxSheet, c.pendingResumeSheet + 1)
                } label: { Label("Later page", systemImage: "chevron.right") }
                .disabled(c.pendingResumeSheet >= c.confirmMaxSheet)
            }

            Text("Check the last printed sheet in your stack: the preview above should be the page right after it. If not, use the arrows until it is.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                c.confirmResume()
            } label: {
                Label("Print from this page", systemImage: "printer.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Button("Back") { c.resetToSetup() }
        }
    }
}

// MARK: - Step indicator (fronts → flip → backs)

struct StepBar: View {
    let current: Int   // 1 = printing fronts, 2 = flip, 3 = printing backs
    private let names = ["Print fronts", "You flip", "Print backs"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(i + 1 < current ? Color.green
                                  : i + 1 == current ? Color.accentColor
                                  : Color.secondary.opacity(0.25))
                            .frame(width: 22, height: 22)
                        if i + 1 < current {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.caption.bold())
                                .foregroundStyle(i + 1 == current ? .white : .secondary)
                        }
                    }
                    Text(names[i])
                        .font(.callout)
                        .fontWeight(i + 1 == current ? .semibold : .regular)
                        .foregroundStyle(i + 1 == current ? .primary : .secondary)
                }
                if i < 2 {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Printing screen

struct PrintingView: View {
    @EnvironmentObject var c: PrintController
    let pass: Int

    var body: some View {
        let total = c.totalSheetsThisPass
        VStack(spacing: 16) {
            if c.printMode == .duplex {
                StepBar(current: pass == 1 ? 1 : 3)
            }
            Text(c.printMode == .normal ? "Printing your document"
                 : pass == 1 ? "Printing the fronts (odd pages)" : "Printing the backs (even pages)")
                .font(.title2.bold())
            Text(c.settingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Overall progress
            VStack(spacing: 6) {
                ProgressView(value: Double(min(c.progressDone, total)), total: Double(max(total, 1)))
                HStack {
                    Text("\(c.progressDone) of \(total) sheets done")
                    Spacer()
                    Text("\(max(total - c.progressDone, 0)) to go")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            // What's coming out of the printer right now
            HStack(spacing: 14) {
                if let cur = c.progressCurrent {
                    let dp = c.docPageForSheet(cur, pass: pass)
                    if let img = c.previewImage(docPage: dp) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .border(Color.secondary.opacity(0.4), width: 1)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NOW PRINTING").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("\(c.printMode == .normal ? "Page" : "Sheet") \(cur) of \(total)").font(.title3.bold())
                        if c.printMode == .duplex {
                            Text("Document page \(dp) of \(c.pageCount)").foregroundStyle(.secondary)
                            Text(pass == 1 ? "Front side of the sheet" : "Back side of the sheet")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 190, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the printer to start the first sheet…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // Printer condition / instructions (paper out, reconnecting, …)
            Text(c.statusLine)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            Text(c.printMode == .normal
                 ? "The document is complete when this finishes."
                 : pass == 1
                 ? "When the fronts finish, this screen will show you how to flip the stack."
                 : "Last step — the document is complete after this.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                c.cancelPrinting()
            } label: {
                Label("Pause printing", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            Text("Pausing stops the printer and saves your exact place — resume anytime from the job list, with a preview of the next page.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Flip screen

struct FlipView: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        VStack(spacing: 16) {
            StepBar(current: 2)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Time to flip the paper!").font(.title.bold())
            Text("The fronts (odd pages) are all printed. Once you've flipped the stack as shown below and pressed Continue, the printer will print the backs (even pages 2, 4, 6…).")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Wait until the printer has completely stopped and the last page is out.")
                step(2, "Pick up the whole printed stack from the front tray. Keep the sheets in exactly the same order — don't shuffle them.")
                step(3, "Turn the whole stack over in one motion, like turning the page of a giant book. The printed side should now face down / away from you.")
                step(4, "Place the stack back into the rear paper slot, blank side facing you, top edge pointing down into the printer.")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))

            if c.hasUnpairedSheet {
                Label("Your document has an odd number of pages — one sheet will stay in the paper tray at the end. Its back is meant to be blank.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                c.continueAfterFlip()
            } label: {
                Label("I flipped the paper — continue printing", systemImage: "play.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Button("Flip later — back to the job list") { c.cancelPrinting() }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }
}

// MARK: - Done screen

struct DoneView: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("All done!").font(.largeTitle.bold())
            Text(c.printMode == .normal
                 ? "\(c.pageCount) page\(c.pageCount == 1 ? "" : "s") printed."
                 : "\(c.pageCount) pages printed on \(c.sheetCount) sheets.")
                .foregroundStyle(.secondary)
            if c.hasUnpairedSheet {
                Text("One sheet stayed behind in the rear paper tray — you can take it out now (its back is blank).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Print another document") { c.resetToSetup() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Failed screen

struct FailedView: View {
    @EnvironmentObject var c: PrintController
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Something went wrong").font(.title.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Back") { c.resetToSetup() }
                .buttonStyle(.borderedProminent)
        }
    }
}
