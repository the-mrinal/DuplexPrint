import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct DuplexPrintApp: App {
    @StateObject private var controller = PrintController()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 760)
        }
    }
}

// MARK: - Model

enum Stage {
    case setup
    case confirmResume
    case printing(pass: Int)
    case flip
    case done
    case failed(String)
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

    // Settings chosen once, applied to both passes
    @Published var quality = "Normal"          // Draft / Normal / Fine / Best
    @Published var blackAndWhite = false
    @Published var paper = "A4"
    @Published var reverseEvens = UserDefaults.standard.bool(forKey: "reverseEvens") {
        didSet { UserDefaults.standard.set(reverseEvens, forKey: "reverseEvens") }
    }
    @Published var rotateEvens = UserDefaults.standard.bool(forKey: "rotateEvens") {
        didSet { UserDefaults.standard.set(rotateEvens, forKey: "rotateEvens") }
    }

    @Published var jobs: [SavedState] = []
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

    private static var stateDir: URL {
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
        if let st = activeState { deleteJob(st) }
        activeState = nil
    }

    func deleteJob(_ st: SavedState) {
        try? FileManager.default.removeItem(at: Self.jobDir(st.id))
        jobs.removeAll { $0.id == st.id }
        if activeState?.id == st.id { activeState = nil }
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

    var sheetCount: Int { (pageCount + 1) / 2 }
    var hasUnpairedSheet: Bool { pageCount % 2 == 1 && pageCount > 1 }

    let qualities = ["Draft", "Normal", "Fine", "Best"]
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

    // MARK: Job options

    private func jobOptions(evenPass: Bool) -> [String] {
        var o: [String] = ["-o", "PageSize=\(paper)"]
        if isEpson {
            let map = ["Draft": "308", "Normal": "303", "Fine": "305", "Best": "307"]
            o += ["-o", "EPIJ_Qual=\(map[quality] ?? "303")"]
            o += ["-o", "EPIJ_BSSv=0"]   // never skip blank pages: it would shift front/back pairing
            o += ["-o", blackAndWhite ? "EPIJ_Ink_=0" : "EPIJ_Ink_=1"]
            if blackAndWhite { o += ["-o", "ColorModel=Mono"] }
        } else {
            let map = ["Draft": "3", "Normal": "4", "Fine": "4", "Best": "5"]
            o += ["-o", "print-quality=\(map[quality] ?? "4")"]
            o += ["-o", blackAndWhite ? "print-color-mode=monochrome" : "print-color-mode=color"]
        }
        o += ["-o", evenPass ? "page-set=even" : "page-set=odd"]
        // The Epson PPD's DefaultOutputOrder is Reverse — always pin the order
        // explicitly or pages come out back-to-front.
        let wantReverse = evenPass && reverseEvens
        if isEpson {
            o += ["-o", "OutputOrder=\(wantReverse ? "Reverse" : "Normal")"]
        } else {
            o += ["-o", "outputorder=\(wantReverse ? "reverse" : "normal")"]
        }
        if evenPass && rotateEvens { o += ["-o", "orientation-requested=6"] }
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
        // Work from an app-private copy so resume works even if the original
        // file is moved, renamed, or on a disconnected drive after a reboot.
        let id = UUID().uuidString
        let work = Self.jobDir(id).appendingPathComponent("document.pdf")
        try? FileManager.default.createDirectory(at: Self.jobDir(id), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: url, to: work) } catch {
            stage = .failed("Couldn't read the PDF file. Please choose it again.")
            return
        }
        previewDoc = PDFDocument(url: work)
        activeState = SavedState(
            id: id, pdfPath: work.path, originalName: url.lastPathComponent,
            pageCount: pageCount, printer: selectedPrinter,
            quality: quality, blackAndWhite: blackAndWhite, paper: paper,
            reverseEvens: reverseEvens, rotateEvens: rotateEvens,
            pass: 1, sheetsCompleted: 0, awaitingFlip: false,
            jobID: nil, passRangeEnd: nil, updatedAt: Date())
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
        if st.pass == 1, let end = st.passRangeEnd { return (end + 1) / 2 }
        return st.pass == 1 ? (st.pageCount + 1) / 2 : st.pageCount / 2
    }

    func docPageForSheet(_ sheet: Int, pass: Int) -> Int {
        pass == 2 ? 2 * sheet : 2 * sheet - 1
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
                let docPage = passIsEven ? 2 * next : 2 * next - 1
                guard await submit(evenPass: passIsEven, fromDocPage: docPage) else { stopKeepAwake(); return }
            }
            await waitForDrain(token: token)
            finishPass(token: token)
        }
    }

    private func finishPass(token: Int) {
        guard token == runToken else { return }
        if case .failed = stage { return }
        if !passIsEven && pageCount >= 2 {
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
        passIsEven ? pageCount / 2 : (pageCount + 1) / 2
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
                let docPage = passIsEven ? 2 * next : 2 * next - 1
                guard await submit(evenPass: passIsEven, fromDocPage: docPage) else { return }
                lastPage = 0
                lastAdvance = Date()
            }
        }
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

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject var c: PrintController

    var body: some View {
        Group {
            switch c.stage {
            case .setup: SetupView()
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

            // Settings — chosen once, used for both sides
            GroupBox("Print settings (applied to the whole book)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Printer", selection: $c.selectedPrinter) {
                        ForEach(c.printers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")) }
                    }
                    Picker("Paper size", selection: $c.paper) {
                        ForEach(c.papers, id: \.self) { Text($0) }
                    }
                    Picker("Quality", selection: $c.quality) {
                        ForEach(c.qualities, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
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
                    Toggle("Rotate the second side 180°", isOn: $c.rotateEvens)
                    Button("Use a 4-page test document") { c.useTestDocument() }
                    Text("Tip: print the 4-page test first. If the backs come out on the wrong sheets or upside down, adjust the two switches above — DuplexPrint remembers them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            if c.sheetCount > 30 {
                Label("Your printer's output tray holds about 30 sheets. This book uses \(c.sheetCount) — collect the printed pages as they pile up, keeping them in order.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if c.pdfURL != nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if c.pageCount < 2 {
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
        let total = st.pass == 1 ? (st.pageCount + 1) / 2 : st.pageCount / 2
        return "\(st.pass == 1 ? "First" : "Second") side: \(st.sheetsCompleted) of \(total) sheets printed · \(st.updatedAt.formatted(date: .abbreviated, time: .shortened))"
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
            Text("This is the next page that will come out of the printer, on the \(pass == 1 ? "front" : "back") of sheet \(c.pendingResumeSheet).")
                .multilineTextAlignment(.center)
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

                Text("Sheet \(c.pendingResumeSheet) of \(c.confirmMaxSheet)")
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
            StepBar(current: pass == 1 ? 1 : 3)
            Text(pass == 1 ? "Printing the fronts (odd pages)" : "Printing the backs (even pages)")
                .font(.title2.bold())

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
                        Text("Sheet \(cur) of \(total)").font(.title3.bold())
                        Text("Document page \(dp) of \(c.pageCount)").foregroundStyle(.secondary)
                        Text(pass == 1 ? "Front side of the sheet" : "Back side of the sheet")
                            .font(.callout).foregroundStyle(.secondary)
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

            Text(pass == 1
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
            Text("\(c.pageCount) pages printed on \(c.sheetCount) sheets.")
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
