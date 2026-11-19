# Rejected benchmark runs

Kept for transparency, not used by `ejm charts`.

- `m1max-gpu32-2026-11-13-1224.json`: during the 1200x800 encode case both the GPU (1.25 ms GPU time against
  0.45-0.54 ms in every other run) and the CPU (libjpeg-turbo 7.29 ms against 2.19-2.39 ms) ran 2-3x slower, while
  every other case matched the other runs: a system-wide disturbance during that case (a macOS disk-cleanup process
  was using about two cores; load average 46 when the run ended). Replaced by the 12:26 run.
- `m1max-gpu32-2026-11-13-1253.json`: its batch-throughput variants ran for a fixed small number of images (as
  little as ~30 ms for the small encodes), too short to be stable; throughput runs are now time-based (at least
  1.5 s per variant). Replaced by the 12:58 run.

The 12:26 and 12:58 runs named above were themselves retired on 2026-11-18, when the runs of that morning
(the 08:32 M1 Max run, later retired below, and `m4-gpu8-2026-11-18-0744.json`) replaced every 2026-11-13
record; they remain in git history.

The M1 Max 08:32 run of 2026-11-18 was retired the same day: macOS CacheDelete held 3-4 CPU cores while it ran,
so its CPU timings were not usable. The 13:45 run on a quiet machine (`m1max-gpu32-2026-11-18-1345.json`)
replaced it; it remains in git history.
