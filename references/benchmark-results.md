# Controlled-fixture measurements

Latest controlled-fixture status: **v5 passed**. Its 100 completed commands all
finished within one second, without observed foreground/active-Space changes.
This does not establish the cause of the earlier v4 changes, or acceptance of
the broader arbitrary-application requirement. All earlier failures remain below.

Measurements use owned synthetic AppKit windows on one Apple Silicon Mac. The
complete CLI timer includes Python startup, the local socket request, native
mutation, and verification of actual window geometry. It excludes model/network
time. Building/installing the helper and starting a real document application are
separate operations. These measurements establish no hard real-time guarantee.

| Run | Completed geometry | Complete CLI <1s | Median | p95 | Maximum | Idle CPU, one core |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| v1: native subprocess per request | 100/100 | 99/100 | 457.365 ms | 500.014 ms | 1391.275 ms | 8.834% |
| v2: scoped cache and snapshot optimization | 100/100 | 100/100 | 249.851 ms | 321.447 ms | 332.946 ms | 6.811% |
| v3: persistent native helper | 100/100 | 100/100 | 174.053 ms | 223.911 ms | 478.807 ms | 3.367% |
| v4: 1 Hz idle polling, new windows and panel | 99/100 | 96/100 | 167.944 ms | 706.563 ms | 2415.125 ms | 0.796% |
| v5: real-time context and stop guards | 100/100 | 100/100 | 178.505 ms | 211.703 ms | 225.476 ms | 0.854% |

Actual **gpt-6-luna** trial: the installed skill completed **6/6 real layouts**
from **3 working directories**, with median **180.598 ms** and
maximum **209.096958 ms** for the complete command. Every call verified
actual changed geometry, the target Space, unchanged before/after context,
and the one-second deadline. The earlier Luna v1 trial stopped after a
context discrepancy and remains unresolved. This trial does not establish
automatic instruction or skill loading in every Codex host.

v5 cold API startup took 166.563 ms with an already compiled helper. Thirty state
queries took a median of 39.172 ms and maximum of 69.081 ms. Combined per-process
peak RSS for the daemon and live helper was 41,418,752 bytes. CPU measurements
include the live native helper and reaped children. This is not an installation
or first-compile latency result.

v5 adds a real-time foreground PID query and stops remaining mutations on a
context change, without trying to restore focus. Its observer recorded 656 samples
with a maximum interval of 34.834 ms and no wrong-Space, fixture-foreground, or
target-Space activation samples. Local event-type auditing recorded no mouseDown,
keyDown, app-active, or window-key event in the fixture. Source hashes stayed
unchanged throughout the run. These finite samples do not exclude shorter
changes between samples.

The v4 metadata observer recorded 911 samples with a maximum interval of
108.533 ms. It observed no wrong-Space fixture window, but it did observe the
fixture becoming foreground and its Space becoming active during the run.
Sampling cannot rule out shorter events between samples. No screenshots or UI
contents were collected. The run also overlapped a separate controlled-fixture
trial, so the observations alone do not establish the activating caller.

A first service start immediately after installing a copied, newly rebuilt helper took 1,223.109 ms and returned `deadline_met:false`. An earlier first helper invocation after compilation took 1,138 ms. These setup/cold-path misses remain part of the evidence; the precompiled cold API and warm-layout pass are narrower claims.

Opening tests revealed a concrete boundary: process-to-Space binding alone does
not safely constrain every panel type. An inactive default NSPanel initially had
no Space; another configuration joined all Spaces. Both remained alpha zero and
were rejected before reveal. Explicit `NSWindowCollectionBehaviorManaged` made
this owned panel verify one target Space before reveal. It does not establish
that arbitrary applications or modal loops can be opened safely.

The default live allocator refused correctly because there was no confirmed
empty inactive Desktop. v4 and v5 therefore used an explicitly authorized inactive
experiment Desktop without moving its other windows. Automatic reservation has
in-memory regression coverage; these runs did not validate live automatic
allocation into an empty Desktop.

Reproduce from the repository root:

```sh
python3 -m unittest discover -s tests -p test_workspace_service.py -v
python3 tests/benchmark_owned_fixture.py --samples 100
```

The live runner compiles its own fixture, uses an isolated local socket, and
terminates only its owned process and service. It records every sample and actual
readback under gitignored `.local/benchmarks`. It refuses when automatic
allocation has no empty inactive Desktop. `--workspace N` selects a specifically
authorized inactive experiment Desktop; it never makes one available by moving
user windows. See [machine-readable aggregates](benchmark-results.json).

## Fresh-agent onboarding (separate from program latency)

All four trials used fresh-context Luna agents, with only an AGENTS location and a natural-language task. No window IDs, Space numbers, bundle ID or API command was supplied. They demonstrate a usable route, not universal instruction loading in every host.

| Trial | Calls before/including first action | Extra discovery | Program time | Dispatch to action |
| --- | ---: | --- | ---: | ---: |
| 1: make the right window primary | 2 | None | 286.883 ms | 34.530 s |
| 2: equal-width columns | 4 | One `--help` | 354.493 ms | 38.004 s |
| 3: columns after recipe clarification | 2 | Memory-registry search in first batch | 205.310 ms | 33.971 s |
| 4: strict cold-context metadata query | 2 | None before first action | 57.830 ms timed repeat | Not recorded |

Trial 2 motivated explicit `columns`/`rows` recipes; trial 3 motivated an explicit self-contained/live-state rule. Trial 4 allowed only AGENTS, the matching skill and current metadata. It issued the correct read-only query after one skill read, but repeated the query to preserve its output: initial raw output and first-action timing were not saved. Its timed repeat is not a first-action measurement. All these limitations are retained.

Dispatch timing includes model, orchestration and tool/network roundtrips, which were not separately measured. A fast native command does not prove instant agent reaction. The code and documentation now support app-name plus `keep` execution without a separate lookup; the broader speed goal is not certified by selecting a favorable trial.

The live privacy schema contains only application/window/Space/geometry/stacking/type metadata and service/focus counters. It contains no title, URL, document path, body text or image field. No collection change was needed for this audit. A later first start after installing a rebuilt helper took 1,354.061 ms; both installation cold-path misses remain recorded.
