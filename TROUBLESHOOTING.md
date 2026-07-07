# DuplexPrint — Troubleshooting Journal

Everything we hit while building DuplexPrint and printing a real 94-sheet book on the
Epson L130 (7 July 2026), with root causes and fixes. Read this before debugging
anything printer-related on this machine.

---

## 1. Queue disabled itself: "Unable to send data to printer"

**Symptom:** Job stuck at "waiting"; `lpstat -p` showed
`printer EPSON_L130_Series disabled — Unable to send data to printer.`

**Root cause:** USB connection dropped. CUPS's default error policy (`stop-printer`)
pauses the whole queue when the backend fails.

**Fix:**
- Immediate: `cupsenable <queue>` re-enables (no sudo needed for the owner).
- Permanent: `lpadmin -p <queue> -o printer-error-policy=retry-current-job`
  (set on both queues) so a failed send auto-retries instead of freezing the queue.
- If `cupsenable` immediately flips back to disabled, the printer is truly
  unreachable — check `ioreg -p IOUSB -l -w0 | grep "USB Product Name"` to see if
  the printer is even on the USB bus. If absent: cable/power problem, not software.

## 2. macOS created a duplicate queue on reconnect

**Symptom:** After replugging the printer a second queue `EPSON_L130_Series_2`
appeared and became the default; the old queue kept the stale stuck job.

**Note:** Harmless but confusing. Jobs live per-queue. Check `lpstat -t` to see all
queues and which is default. The old queue can be deleted in System Settings.

## 3. Mid-job freeze: `com.epson.COM_001-error`

**Symptom:** Job frozen at "Page 15 of 94" for many minutes. CUPS state stayed
`processing`; queue not disabled. IPP showed
`printer-state-reasons = com.epson.COM_001-error`.

**Root cause:** COM_001 is the Epson driver's *communication error* — the USB link
died mid-stream. The printer may re-enumerate on the bus, but the half-sent job's
data stream is lost forever. CUPS cannot rewind; the wedge often needs a printer
power-cycle before new jobs flow.

**Fix (manual):** cancel the job, power-cycle the printer, resubmit **only the
remaining pages** with `-o page-ranges=N-M` (see §5 for finding N).
**Fix (in app):** the watchdog classifies reasons; on connection-type errors it
cancels the dead job, waits for the printer to return, and resubmits from the last
completed sheet automatically.

**Contributing factor:** `pmset -g` showed **system sleep = 1 minute**. A sleeping
Mac cuts USB power mid-job. The app now runs `caffeinate -ims` while printing.

## 4. Reading the spooled job when the source file/settings are unknown

**Problem:** To resume someone's print you need the exact document CUPS received and
the exact job options.

**How:**
- Job name: `lpq -P <queue> -l` (shows e.g. `M2_LINEARALGEBRA.pdf`).
- Full job options: custom ipptool test with `OPERATION Get-Job-Attributes` +
  `ATTR integer job-id N` — reveals `page-set`, `page-ranges`, `OutputOrder`,
  `EPIJ_Qual`, `Resolution`, everything Preview set.
- The spooled document itself: `/private/var/spool/cups/d000NN-001` (root-only).
  `sudo` fails in non-TTY contexts ("a terminal is required") — use
  `osascript -e 'do shell script "cp ..." with administrator privileges'`
  which pops the native password dialog.
- **Copy the spool file BEFORE cancelling the job** — cancel can delete it.
- Gotcha: Preview may spool a *different page count* than the source PDF
  (here: 187-page spool from a 242-page PDF — Preview had a page selection), and
  imposition options like `page-set=odd` are job options applied by CUPS filters,
  not baked into the spooled PDF.

## 5. Pages printed in REVERSE order after resubmit

**Symptom:** Resumed job printed last pages first. User caught it.

**Root cause:** The L130 PPD contains `*DefaultOutputOrder: Reverse`. Preview always
overrides it with `OutputOrder=Normal`; our `lp` resubmit didn't, so the driver
default kicked in.

**Fix:** **Every** `lp` submission must pin the order explicitly:
`-o OutputOrder=Normal` (Epson PPD keyword) or `-o outputorder=normal` (generic
CUPS). The app hardcodes this into `jobOptions()` for every pass and every
recovery resubmit.

## 6. Out of paper: `com.epson.ER06_005-error, media-empty`

**Symptom:** Printing stops mid-pass; reasons show `media-empty`.

**Key insight:** This is a *user-fixable* condition — the job is NOT lost. The
printer continues by itself once paper is loaded (press the blinking paper button).
Never cancel/resubmit for this class — that's how duplicates happen. The app's
watchdog treats `media-empty`, `media-jam`, `cover-open`, `door-open`,
`marker-supply*` as wait-forever-with-instructions.

## 7. CUPS lied: job marked "completed" that never fully printed

**Symptom:** Job 11 showed `job-state = completed`, but the printer had physically
stopped at sheet 23 (interrupted paper-out). Trusting the status nearly marked the
whole first side done with 68 sheets missing.

**Root cause:** "Completed" in CUPS means *data handed to the printer*, not *ink on
paper*. An interrupted error state can flush the job as "done". Also,
`job-media-sheets-completed` is always 0 with this Epson driver — useless.

**Fix / lesson:**
- **The printed page numbers in the user's hands are the only ground truth.**
- The app now shows a **confirm-resume screen with a rendered preview of the next
  page**, letting the user shift the starting sheet until it matches their stack.
- Mapping trick from this incident: user's book page = spool page + 34; last
  printed book page 79 = file page 45 = sheet 23.

## 8. Stale record → duplicate reprint (split-brain)

**Symptom:** User pressed Resume in the app while a rescue job was being managed
*outside* the app (from the terminal). The app's record said 14 sheets, reality was
23; it resubmitted from sheet 15 and printed a duplicate before the user cancelled.

**Lesson:** One source of truth. Once a job is in the app, drive it ONLY through
the app. If external management is unavoidable, patch the app's `job.json`
(and relaunch the app — it caches records in memory) before anyone presses Resume.

## 9. Progress parser blind on resumed jobs: "Page 9 of **-22**"

**Symptom:** After resuming with `page-ranges`, saved progress never advanced; the
progress UI showed nothing; and after 7 idle-looking minutes the stall watchdog
would have "recovered" (= duplicated pages) a perfectly healthy print.

**Root cause:** On ranged jobs the Epson driver reports the total as a NEGATIVE
number in `printer-state-message` ("Page 9 of -22"). Our regex `Page (\d+) of (\d+)`
required a positive total, so it never matched.

**Fix:** `Page (\d+) of (-?\d+)` — only the first group (current page) is used.

## 10. Re-attach progress math was wrong after app restart

**Symptom:** Reopening the app mid-print and re-attaching to the live CUPS job
would have double-counted sheets.

**Root cause:** A live job's "Page N" counter starts where *that job* began (e.g.
sheet 24), not where the pass began. Attaching with `offset = sheetsCompleted`
(which keeps advancing) double-counts.

**Fix:** `SavedState.jobBaseSheets` records the pass offset at submit time; attach
always uses that.

## 11. Assorted CUPS/Epson facts worth remembering

- PPD path: `/etc/cups/ppd/EPSON_L130_Series_2.ppd`. No `*Duplex` keyword — the
  L130 has zero duplex support; manual flip is the only way.
- Quality values: `EPIJ_Qual` 301 FastEconomy / 302 Economy / 308 Draft /
  303 Normal (default) / 304 Fine / 305 Quality / 306 HighQuality / 307 Best.
- Grayscale: `EPIJ_Ink_=0` (+ `ColorModel=Mono`). Colour: `EPIJ_Ink_=1`.
- `EPIJ_BSSv=0` always — "Skip Blank Page" silently shifts front/back pairing.
- `page-set=odd|even` + `page-ranges=N-M` combine safely **if N matches the
  parity you're printing** (start odd ranges on an odd page) — then both possible
  filter interpretations select the same pages.
- Page count without tools: `mdls -name kMDItemNumberOfPages file.pdf`.
- Printer state+reasons: `ipptool -tv ipp://localhost/printers/<Q>
  get-printer-attributes.test` (test file ships with CUPS).
- Output tray holds ~30 sheets; input ~50 (94-sheet passes overflow — collect in
  order mid-print).
- If the total number of pages is odd, the final sheet has no even page: with
  normal order it simply never feeds on the even pass and stays in the tray.
