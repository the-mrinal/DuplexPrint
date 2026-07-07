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

## 6. The book that built this app

The whole thing was forged printing `M2_LINEARALGEBRA.pdf` (187-page selection,
book page = file page + 34): USB death at sheet 15, spool rescue with admin
rights, reverse-order mishap (3 tail sheets printed early — job's `passRangeEnd`
is 181 so resubmits never duplicate them), paper-out at sheet 23+, a CUPS
"completed" lie, one duplicate sheet caught by the user, and finally a smooth run.
Every failure became a feature. See `TROUBLESHOOTING.md` for each incident.

## 7. Roadmap — not yet built

- **Batching** for passes > 30 sheets (output tray capacity) — chunked
  odd→flip→even cycles, or at least a "tray nearly full" nudge.
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
