# DuplexPrint — Project Plot

The story, design, and roadmap of DuplexPrint: a macOS app that gives a cheap
single-sided printer (Epson L130) a friendly, bulletproof two-sided printing
workflow. Built 7 July 2026, battle-tested the same day on a real 94-sheet book.

---

## 1. The problem

The Epson L130 has **no duplexer** (its driver PPD contains no `Duplex` keyword at
all). Printing a book double-sided means: print odd pages → flip the stack by hand
→ print even pages. Doing that through Preview requires diving into print dialogs
twice, picking "odd pages only" then "even pages only", re-choosing quality and
colour each time, and praying nothing goes wrong across ~45 minutes of printing.
On this machine plenty went wrong: USB drops, paper-out, driver wedges, reverse
page order, and a Mac that sleeps after 1 minute and cuts USB power.

## 2. The answer

**DuplexPrint.app** — a native SwiftUI app usable by someone with zero technical
knowledge:

1. Drop in a PDF, choose printer/paper/quality/colour **once**.
2. A "What will happen" box explains the 3 steps before anything prints.
3. It prints the fronts (odd pages), watching every sheet.
4. A big friendly screen shows exactly how to flip the stack.
5. It prints the backs (even pages). Done — the only touch is the flip.

Under the hood it shells out to CUPS (`lp`, `lpstat`, `cancel`, `cupsenable`,
`ipptool`) — zero dependencies, nothing to install.

## 3. Where things live

| What | Where |
|---|---|
| Source (single file) | `Documents/DuplexPrint/DuplexPrint.swift` |
| App bundle (built) | `Documents/DuplexPrint/DuplexPrint.app` |
| Installed app | `~/Applications/DuplexPrint.app` |
| Job library (persistent) | `~/Library/Application Support/DuplexPrint/jobs/<id>/{job.json, document.pdf}` |
| Book library (split/extracted PDFs) | `~/Library/Application Support/DuplexPrint/books/<id>/{book.json, part-1.pdf …}` |
| Rescued book spool file | `Documents/DuplexPrint/resume-job9.pdf` (187 pages) |
| Debug journal | `Documents/DuplexPrint/TROUBLESHOOTING.md` |

**Build command:**
```sh
swiftc -O -parse-as-library -target arm64-apple-macos13.0 DuplexPrint.swift \
  -o DuplexPrint.app/Contents/MacOS/DuplexPrint
codesign --force --deep -s - DuplexPrint.app
```
(The SourceKit editor warning about `@main` is noise — `-parse-as-library` fixes it.)

## 4. Architecture

One `PrintController` (`@MainActor ObservableObject`) drives a stage machine:

```
setup ──▶ printing(pass 1) ──▶ flip ──▶ printing(pass 2) ──▶ done
   ▲            │  ▲                          │
   │            ▼  │ (resume w/ preview)      ▼
   └────── confirmResume ◀── job list ◀── pause/failure/quit/reboot
```

Key pieces:

- **`SavedState`** — one JSON per job: document copy, ALL settings (quality,
  colour, paper, printer, calibration flags — frozen at job creation), pass,
  sheets completed, live CUPS job id + its base offset. Saved after **every
  sheet**. Deleted only when both sides finish.
- **Watchdog loop** (`waitForDrain`) — polls CUPS every 3 s via `ipptool`,
  classifies `printer-state-reasons`:
  - *User-fixable* (`media-empty`, jam, cover open): show plain-English
    instructions, wait forever, never cancel.
  - *Connection broken* (`offline`, `com.epson.COM_*`, timeouts): cancel the dead
    job, wait for the printer to come back (power-cycle, replug — up to 30 min),
    resubmit from the last completed sheet. 8 strikes → friendly failure telling
    the user progress is saved.
- **Job library** — list on the home screen: Resume / Start over / Delete.
- **Confirm-resume preview** — before any resubmission, render the actual next
  page (PDFKit) and let the user shift the start sheet until it matches their
  physical stack. The user is the final authority, because CUPS lies (§7 of the
  troubleshooting journal).
- **Auto-attach** — launching the app while the printer is mid-job on one of its
  jobs jumps straight to the live progress screen.
- **Progress screen** — progress bar, sheets done/remaining, "NOW PRINTING" panel
  with a window-filling preview of the exact page being printed, printer-condition
  box, and a **Pause** button (safe: stops printer, saves place; resume goes
  through the preview screen).
- **Keep-awake** — `caffeinate -ims` runs while printing (the Mac's 1-minute sleep
  setting cuts USB power otherwise).
- **Safety constants** in every submission: `OutputOrder=Normal` (the L130 PPD
  defaults to Reverse!), `EPIJ_BSSv=0` (skip-blank-page shifts duplex pairing).
- **Print modes** (v4) — a `PrintMode` picker: `duplex` (the classic two-pass
  flip flow) or `normal` (single pass, whole document, no flip). The mode is
  frozen per job (`SavedState.printMode`, nil = duplex for pre-v4 jobs) and all
  sheet math routes through `docPageForSheet`/`totalSheetsThisPass`, which are
  mode-aware (normal: sheet N = page N). `jobOptions` branches on mode — normal
  emits no `page-set`/`orientation-requested`, but still pins `OutputOrder` and
  `EPIJ_BSSv=0`.
- **Book library** (v4, reworked v4.1) — "Split this PDF or pick pages…" on the
  setup screen opens a full-window **split screen** (`Stage.split`, `SplitView`):
  two tabs, "Equal parts" (stepper; per-part cards show first/last page
  thumbnails, page range, sheet count, an expandable grid of EVERY page inside,
  and ◀ ▶ arrows that move each boundary — by 2 pages in duplex so starts stay
  odd/fresh-sheet) and "Just some pages" (typed ranges "5-20, 35, 40-42", kept
  in typed order, with a live thumbnail grid of exactly what you'll get).
  Nothing is written until the confirm button; `splitLoadedDocument(atStarts:)`
  takes the explicit boundary list (`partSizes` still computes the even-snapped
  defaults; 187÷4 → 48/48/48/43). Parts are real PDFs built with PDFKit (page
  *copies* — inserting live pages would re-parent them). Confirming lands on the
  **book detail page** (`Stage.book(id)`, `BookDetailView`): one card per part
  with thumbnail, status (Not printed / In progress / Printed — derived from the
  jobs list + `BookPart.printed`), Print / Resume / Print again, "Save a copy…"
  export, per-part reset, expandable all-pages grid, and book-level delete. The
  main screen lists books as compact rows with an Open button (`BooksSection`).
  Printing a part goes through the ordinary job pipeline (`startJob` with
  `bookID`/`partIndex`); `clearState()` marks the part printed when both sides
  finish. `Book.printMode` is frozen at split time and re-applied by `printPart`
  (a normal-snapped book printed duplex would bleed a sheet's back across parts).
- **Self-test harness** (v4) — `DuplexPrint --selftest` (hidden CLI flag) checks
  the split/range/jobOptions maths, old-format `job.json` decoding, and a real
  on-disk split, then exits. Run it after any change.

## 5. Version history (all on 7 July 2026)

| Version | What was added |
|---|---|
| v1.0 | Core two-pass flow, settings once, flip screen, queue polling |
| v1.1 | `caffeinate` keep-awake; stall watchdog with auto-resume from stalled sheet; `retry-current-job` queue policy |
| v1.2 | Pin `OutputOrder=Normal` everywhere (reverse-order incident) |
| v2.0 | Persistent state per sheet; resume after quit/reboot/crash; reason classification (user-fixable vs connection); re-attach to surviving CUPS jobs |
| v3.0 | Multi-job library with Resume / Start over / Delete; jobs cleaned only when fully done; cancel keeps the job |
| v3.1 | Every setting frozen per job (incl. calibration flags) |
| v3.2 | "What will happen" roadmap + step bar (fronts → flip → backs) with next-step hints |
| v3.3 | Confirm-resume screen with page preview and adjustable start sheet |
| v3.4 | Rich progress screen (bar, counts, current-page panel) + Pause; `jobBaseSheets` re-attach fix |
| v3.5 | Progress parser accepts Epson's negative totals ("Page 9 of -22") — fixed blindness + false-recovery risk |
| v3.6 | Auto-attach to live jobs on launch |
| v3.7–v3.8 | Large, window-filling, high-res previews |
| v4.0 (8 Jul) | Print-mode picker (two-sided / normal single-pass); book library: split a PDF into N parts (even-snapped boundaries) or extract typed page ranges, with per-part printed-status tracking and Save-a-copy export; `--selftest` harness |
| v4.1 (8 Jul) | Visual split screen: per-part first/last-page thumbnails, expandable every-page grids, adjustable boundaries (fresh-sheet parity kept in duplex); dedicated book detail page (Print/Resume per part) reached after splitting or via Open on the main screen |
| v4.2 (8 Jul) | Preview-size slider (AppStorage, shared by all grids) + click-any-thumbnail full-page viewer with ←/→; split-screen crash fix (§11 of troubleshooting); print-a-part confirmation sheet showing/editing every setting before the job starts; settings summary line on printing & resume screens; quality/paper/colour persisted across launches; full 8-level Epson quality ladder (Fast Economy 301 → Best 307) with Epson's own names |

## 6. The book that built this app

The whole thing was forged printing `M2_LINEARALGEBRA.pdf` (187-page selection,
book page = file page + 34): USB death at sheet 15, spool rescue with admin
rights, reverse-order mishap (3 tail sheets printed early — job's `passRangeEnd`
is 181 so resubmits never duplicate them), paper-out at sheet 23+, a CUPS
"completed" lie, one duplicate sheet caught by the user, and finally a smooth run.
Every failure became a feature. See `TROUBLESHOOTING.md` for each incident.

## 7. Roadmap — not yet built

- ~~**Batching** for passes > 30 sheets~~ — covered by v4's split-into-parts
  (split a big book so each part's pass fits the tray).
- **Calibration wizard** — the 4-page test exists (Advanced), but a guided
  first-run wizard that asks "which of these came out right?" and sets the two
  flags automatically would be friendlier.
- **Media type** per job (plain / matte / glossy) — currently always plain.
- **Notifications** — macOS notification when it's flip time or paper runs out,
  so the user doesn't have to watch the screen.
- **Estimated time remaining** — sheets/minute is measurable from progress.
- **Multiple copies** of a document.
- **Queue cleanup helper** — detect and offer to remove duplicate stale queues
  (macOS creates `_2`, `_3`… on USB reconnects).
- **Nice app icon** — current one is a generated placeholder.
