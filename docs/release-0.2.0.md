# zshard 0.2.0: palette and interaction validation

## Result

The default shell now uses one warm copper palette across its prompt, command
highlights, history suggestions and completion headings. Eight
[`ZSHARD_COLOR_*` options](plugins.md#colors) control those surfaces. The prompt
keeps its directory, Git branch, failure status and slow-command duration, with
no icon-font requirement.

Repeated redraws of unchanged input reuse the previous history lookup, including
a miss. The cache is discarded when the input, history event or scan limit
changes, and at the end of an editing line. This saves repeated work while
preserving the bounded search when the user types something new.

Git discovery now refreshes when a repository is created in the current directory
or the cached checkout disappears. Both failures were reproduced on the
unmodified 0.1.3 source and passed after the change. The prompt still reads HEAD
through zsh builtins; it does not run Git or start a watcher.

## Recorded source and method

The comparison uses baseline `a55c2d08b4299b25ec007b45641df87e8c0d0bbb` and updated
runtime `f21edef8621719f960fffcac1bb671f34c6dac34`. Measurement finished on
2026-11-20 at 06:32 Asia/Taipei. The raw JSON retains the UTC timestamp, exact
revisions, samples, kernel, architecture and load average. The measured runtime
still carried the previous version string before the release bump; the source
SHA identifies the code that was executed.

The machine ran Linux x86_64, zsh 5.9.2 and an Intel Core i9-12900HX. Each variant
had an isolated HOME. The interaction benchmark used three warmups and 31
samples in seeded, interleaved order. The first-prompt measurement starts at
`zsh -d -i` launch and ends when the final prompt marker arrives on a real
100×24 PTY. Completion remains deferred.

Hook measurements use zsh's internal clock over batches of 300 calls, including
loop overhead. They measure prompt generation or editor-hook work without
terminal painting. History tests import 250 entries and retain the default
200-event search limit. Unchanged input and changing input are separate cases.

## Interaction results

Milliseconds; lower values mean less elapsed time in this recorded workload.

| Operation | 0.1.3 median | Updated median | 0.1.3 p95 | Updated p95 |
| --- | ---: | ---: | ---: | ---: |
| Process launch to first prompt | 4.0942 | 4.1348 | 6.7236 | 5.7997 |
| Prompt generation inside a repository | 0.0330 | 0.0384 | 0.0629 | 0.0553 |
| Prompt generation outside a repository | 0.0202 | 0.0554 | 0.0287 | 0.0699 |
| Prompt generation with the same custom callback | 0.0363 | 0.0435 | 0.0454 | 0.0710 |
| Repeated history miss, unchanged input | 0.7254 | 0.0695 | 0.9137 | 0.0923 |
| History miss, input changes on each call | 0.6939 | 0.7210 | 0.8574 | 0.9416 |

The repeated-input median fell by about 90.4%, a 10.4× elapsed-time ratio. The changing-input case
did not improve: its median increased by 0.0271 ms. The first prompt stayed near
4.1 ms in this run. The extra repository checks add work, especially outside
Git, in exchange for reflecting newly created or removed repositories.

These results support a specific improvement in redundant history searches.
They do not establish a speed ranking against every framework or show that each
keystroke became 10.4 times faster. The workstation was shared with other work;
the recorded load average was approximately 6.94, 6.01 and 6.19.

[Complete interaction samples](benchmarks/warm-copper-interaction.json)

## Initialization, completion and memory

A separate 31-sample initialization run used the existing benchmark script.
These figures include process launch and initialization and exclude the first
rendered prompt. Memory is the median PSS of five idle shell processes; it
excludes the terminal emulator. All measured idle shells had zero children.

| Updated configuration | Initialization median, ms | p95, ms | Idle PSS, KiB |
| --- | ---: | ---: | ---: |
| Vanilla zsh | 1.530 | 1.727 | 1057 |
| zsh with audited completion | 11.619 | 14.257 | 2612 |
| zshard, completion deferred | 3.655 | 4.704 | 1478 |
| zshard, completion ready | 17.601 | 20.401 | 2792 |

First completion with an existing dump took 14.381 ms median and 18.119 ms p95.
Creating a dump took 153.552 ms median over five samples; its p95 was 203.026 ms.
Installers can explicitly warm that cache. Security auditing remains enabled.

[Updated startup and memory samples](benchmarks/warm-copper-current.json) ·
[Earlier baseline run](benchmarks/warm-copper-baseline.json)

The separate baseline run was not interleaved with the updated startup run, so
differences between those two files are not presented as a causal speedup. The
interleaved interaction comparison above is the comparison used for the claim.

## Local validation

All 37 runtime contracts were covered: 36 passed in the ordinary-user run and
the ownership-transition case passed separately in an isolated sudo test. The
set includes real PTY suggestions, Tab completion, explicit AI proposal staging,
plugin loading, audited completion-cache invalidation and recovery, palette
overrides, RGB output, Git refresh, and suggestion-cache invalidation.

The process trace now enables the actual default prompt when checking that
startup and prompt construction do not fork. A real PTY test observed the
configured RGB escape sequences for both the command token and the suggestion.
Behavior checks cover changes to input, history and scan limits, moving the
cursor away and back, disabled suggestions and another widget's POSTDISPLAY.

```sh
make check
sudo python3 tests/test_runtime.py RuntimeTests.test_changed_completion_file_ownership_invalidates_cache
python3 scripts/benchmark_interaction.py --baseline a55c2d08b4299b25ec007b45641df87e8c0d0bbb --samples 31 --output artifacts/interaction.json
python3 scripts/benchmark.py --samples 31 --output artifacts/startup.json
```

The baseline commit must exist locally. The interaction script exports that
commit into a temporary directory; it does not fetch or alter the checkout.
Daily validation is local. The existing official release workflow still creates
the tagged source archive and checksum.

## Review of the claims

| Question | Evidence and limit |
| --- | --- |
| What changed for the user? | Shared configurable colors, refreshed repository discovery and fewer duplicate history lookups; no new runtime dependency. |
| Can the measurement be repeated? | Scripts, raw samples, exact revisions, warmups, ordering and timing boundaries are recorded. |
| Is the speed claim supported? | The 10.4× ratio applies only to repeated unchanged-input misses; changing-input results are reported beside it. |
| Is coverage complete? | Real PTY and 37 local contracts cover the changed behavior; latency results describe one Linux workstation, not every terminal or plugin combination. |
| Does the design preserve behavior? | Cache invalidation, foreign-display ownership and no-fork checks passed; completion auditing remains intact. |
