# Hardware-memory review — 2026-07-13

## Measured release baseline

All numbers below were measured locally against the release candidate rather
than inferred from source code.

| Scenario | Result |
| --- | --- |
| 16 hidden terminals, 64 MiB total output | 0 output bytes retained in hot RAM; 64 MiB moved to bounded disk storage |
| Savings versus the former 1 MiB-per-terminal main-process rings | 16 MiB managed RAM |
| One idle, resumable Codex ACP session | 2 owned processes, 205,056 KiB RSS (about 200 MiB) |
| The same Codex session after production disposal/parking | 0 processes, 0 KiB RSS |
| Eco/solid renderer, three-round median | 472.7 MiB |
| Live Glass renderer, three-round median | 478.0 MiB |
| Live Glass incremental cost | 5.1 MiB, or 1.1% |

The priority is clear: provider-process lifecycle is a much larger memory lever
than visual material. Disabling Live Glass saves little compared with safely
parking one resumable idle coding-agent process group.

## Shipped policy

- An ordinary visible agent transcript remains warm.
- A private Mesh worker remains warm while connecting, running, streaming, or
  waiting for a permission decision.
- At paused, human-approval, and completed Mesh gates, its lease is released.
  A resumable provider session parks after 30 seconds and reconnects on the next
  stage without losing provider state.
- A provider that cannot resume/load, a running turn, or a permission wait is
  never parked.
- Hidden terminal output is spooled to disk with a bounded fallback if disk
  writes fail.
- Assistant live history remains bounded and older turns page from the
  append-only archive.
- Reversibly closed sessions keep lightweight state; live terminal resources
  are reaped after the grace period.

## Further options, in priority order

1. **Archive completed private-worker transcripts more aggressively.** The
   parent already owns stage snapshots and terminal receipts. After completion,
   retain the audit trail on disk and hydrate it only when a user opens the
   worker detail. Expected win: moderate renderer memory; risk: medium, so add
   close/reopen and archive-failure tests first.
2. **Content-address large Mesh packets.** Store long peer reports once and pass
   bounded summaries plus references. Expected win: moderate memory and token
   throughput for four-to-six-participant teams; risk: low-to-medium.
3. **Expose an explicit “keep agents warm” project preference.** The safe
   default remains adaptive parking, while latency-sensitive users could trade
   memory for instant next-stage starts. Expected win: user control; risk: low.
4. **Add per-process diagnostics to the Settings memory view.** Attribute RSS
   to renderer, GPU, broker, and each adapter/CLI so regressions are caught at
   the process actually responsible. Expected win: observability; risk: low.
5. **Consider provider-session multiplexing only if ACP adapters support it.**
   Sharing one process across sessions could be large, but forcing it today
   would weaken isolation and provider compatibility. Expected win: high;
   current risk: high, so do not ship speculatively.

Do not save memory by truncating in-flight output, killing non-resumable
sessions, dropping permissions, or collapsing isolated worktrees. Those changes
would reduce capability or recovery guarantees rather than remove idle cost.
