# DuplexPrint

A native macOS app that gives single-sided printers (built for the Epson L130) a
friendly, crash-proof **manual duplex** workflow: print the fronts → flip the
stack once, guided on screen → print the backs. Designed so someone with zero
technical knowledge can print a whole book double-sided.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange) ![Deps](https://img.shields.io/badge/dependencies-none-green)

## Features

- **One-flip duplex**: odd pages, a guided flip screen, even pages — settings
  (quality, colour, paper) chosen once and frozen per job.
- **Job library**: every unfinished print is saved after *every sheet* — quit the
  app, reboot the Mac, or lose power, and it offers to resume exactly where it
  stopped. Jobs are removed only when both sides finish.
- **Confirm-resume with preview**: before resuming, it shows a rendered image of
  the next page and lets you shift the start sheet to match your physical stack —
  because CUPS sometimes lies about what actually printed.
- **Self-healing**: distinguishes user-fixable states (out of paper, jam, open
  cover → plain-English instructions, waits forever) from connection failures
  (USB drop, driver wedge → cancels the dead job, waits for the printer to come
  back, resubmits from the last completed sheet).
- **Live progress**: progress bar, sheets done/remaining, and a window-filling
  preview of the exact page being printed. Safe **Pause** anytime.
- **Keeps the Mac awake** while printing (sleep cuts USB power mid-job).
- Zero dependencies — talks to CUPS via `lp`/`lpstat`/`ipptool`.

## Build & install

Requires Xcode command line tools (Swift 5.7+ / macOS 13+):

```sh
./build.sh          # builds DuplexPrint.app and installs to ~/Applications
```

## Docs

- [`PLOT.md`](PLOT.md) — project story, architecture, version history, roadmap.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — every failure we hit printing a
  real 94-sheet book (USB drops, driver wedges, CUPS lying about completion,
  reverse-order PPD defaults, negative page totals…) with root causes and fixes.

## Printer notes (Epson L130)

The L130 has no duplexer at all. Its driver has two traps this app neutralizes:
`*DefaultOutputOrder: Reverse` (pages come out back-to-front unless explicitly
overridden) and "Skip Blank Page" (silently shifts front/back pairing). See
`TROUBLESHOOTING.md` §11 for the full cheat-sheet.

---

Built with [Claude Code](https://claude.com/claude-code).
