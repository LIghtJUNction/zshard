# Performance and validation

zshard starts with ordinary zsh code and no background process. Its default startup defers completion, plugin management and AI helpers until needed. The complete startup measurement below includes audited completion and keeps that distinction visible.

## 0.2.0 palette and interaction measurements

The warm copper defaults keep real first-prompt delivery near 4.1 ms in a
31-sample interleaved comparison with 0.1.3. Repeated redraws of unchanged input
reuse a bounded history result: that specific miss case measured 0.0695 ms
instead of 0.7254 ms. Changing-input misses measured 0.7210 ms instead of
0.6939 ms, so the cache benefit is not a per-keystroke speed claim.

Default initialization measured 3.655 ms median; initialization with audited
completion ready measured 17.601 ms. Default idle shell PSS was 1478 KiB.
The [0.2.0 validation record](release-0.2.0.md) contains exact source revisions,
all timings, memory boundaries, 37 local runtime contracts and reproducible
commands. Earlier measurements below retain their original source and scope.

## Earlier 0.1.2 measurements

Source commit: `3367c8dadef1a06a047ce9b47aa9446fe219550c`. zsh: `zsh 5.9.2 (x86_64-pc-linux-gnu)`. CPU: 12th Gen Intel(R) Core(TM) i9-12900HX. Raw timestamp: 2026-11-19T20:06:22.203002+00:00.

| Configuration | Initialization median, ms | p95, ms | Idle PSS, KiB |
| --- | ---: | ---: | ---: |
| Vanilla zsh | 1.679 | 2.005 | 767 |
| zsh + audited completion | 12.291 | 15.236 | 2308 |
| zshard, completion deferred | 4.106 | 5.114 | 1161 |
| zshard, completion ready | 19.185 | 24.213 | 2500 |
| Oh My Zsh, git + robbyrussell | 28.403 | 33.335 | 2824 |

The baseline-to-zshard elapsed-time ratio was 6.92 for default initialization and 1.48 with completion ready. This compares these configurations on one workstation; it does not rank all shells or terminals.

The first completion in each shell took a median of 15.848 ms with a warm disk dump. Creating a new dump took 147.310 ms. The cold cost occurs on the first Tab of a fresh cache; it is not included in the deferred startup figure. Installers can explicitly run `zshard cache warm [COMPLETION_DIR ...]` to pay that cost during installation. Native compinit still rebuilds when its audited completion inputs change.

The script measures 31 interleaved process launches after three warmups, using an empty temporary home. It invokes `zsh -f -i -c` and measures process launch plus initialization; first-prompt rendering is excluded for every variant. PSS comes from five idle processes per variant through `/proc/PID/smaps_rollup`; terminal-emulator memory is excluded. All measured zshard idle processes had zero child processes.

Oh My Zsh is pinned at `c0140703a53eb0d22be44f7bac318d0baacc927c` with the git plugin, robbyrussell theme and automatic updates disabled. The baseline does not add separate suggestion or highlighting plugins. Warm filesystem state, system load, distribution completion files and shell configuration affect these values.

[Raw samples and environment](benchmarks/release-0.1.2.json) include all startup, completion and memory samples.

## Reproduce

~~~sh
make check
python3 scripts/benchmark.py --samples 31 --output artifacts/benchmark.json
# Optional comparison against your reviewed, pinned upstream checkout:
python3 scripts/benchmark.py --samples 31 --omz /path/to/ohmyzsh --output artifacts/with-omz.json
~~~

## Runtime evidence

The 28 runtime contracts passed through local checks and the isolated root ownership-transition test. The tests use temporary homes and actual zsh PTYs. They cover suggestion acceptance, Tab completion, AI proposal staging without execution, JSON escaping, argument-preserving lazy loading, hook coexistence, themes, completion registration, pinned plugin integrity, unload, lock restoration, CLI warming with additional completion directories and a dedicated cache, secure dump reuse, and rejection of a writable dump. A Linux strace check verifies no child process is created by default startup or the built-in prompt.

The public HTTPS example-plugin path was exercised against commit `6ef55fe94dcf0f5f17c8f749041dc2cad6df0590`: install, verify, load, execute the hello command, unload, export, remove, restore and verify all succeeded. No downloaded plugin was loaded by the installation operation.

The 0.1.2 compatibility layer validates the current completion file list and native audit exclusions before reusing a dump. This adds work at first completion compared with 0.1.1; the published measurements include it. [Cache compatibility evidence](completion-cache.md) explains the Ubuntu rebuild loop, ownership-transition regression and atomic publication checks. PSS varies with other processes sharing mapped pages, so compare configurations within one recorded run.

## Claims and review

| Review question | Evidence and boundary |
| --- | --- |
| What was created? | A zsh framework with a small default path and explicit extension APIs; zsh remains the shell. |
| Is the behavior clear? | Deferred initialization and feature-ready initialization have separate measurements; AI actions are explicit. |
| Are performance claims supported? | Raw samples, exact revisions and a reproducible script support this workstation comparison. |
| Is evaluation complete? | Runtime regressions cover Arch zsh 5.9.2 and Ubuntu 24.04 zsh 5.9. Workstation timings describe this recorded configuration; other machines and plugin combinations need their own measurements. |
| Does the design uphold its boundaries? | PTY and process-trace checks cover no automatic command execution and no default child process; plugins remain trusted shell code. |
