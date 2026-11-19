# Performance and validation

zshard starts with ordinary zsh code and no background process. Its default startup defers completion, plugin management and AI helpers until needed. The complete startup measurement below includes audited completion and keeps that distinction visible.

## Measurements

Source commit: `6d2ff96a593f9d34a53455fa12b64348be4d0cf5`. zsh: `zsh 5.9.2 (x86_64-pc-linux-gnu)`. CPU: 12th Gen Intel(R) Core(TM) i9-12900HX. Raw timestamp: 2026-11-19T19:27:19.460015+00:00.

| Configuration | Initialization median, ms | p95, ms | Idle PSS, KiB |
| --- | ---: | ---: | ---: |
| Vanilla zsh | 1.514 | 1.811 | 1533 |
| zsh + audited completion | 12.098 | 14.869 | 3324 |
| zshard, completion deferred | 3.427 | 4.306 | 2171 |
| zshard, completion ready | 13.553 | 15.120 | 3447 |
| Oh My Zsh, git + robbyrussell | 25.650 | 29.645 | 3816 |

The baseline-to-zshard elapsed-time ratio was 7.48 for default initialization and 1.89 with completion ready. This compares these configurations on one workstation; it does not rank all shells or terminals.

The first completion in each shell took a median of 9.929 ms with a warm disk dump. Creating a new dump took 147.113 ms. The cold cost occurs on the first Tab of a fresh cache; it is not included in the deferred startup figure. Installers can explicitly run `zshard cache warm [COMPLETION_DIR ...]` to pay that cost during installation. Native compinit still rebuilds when its audited completion inputs change.

The script measures 31 interleaved process launches after three warmups, using an empty temporary home. It invokes `zsh -f -i -c` and measures process launch plus initialization; first-prompt rendering is excluded for every variant. PSS comes from five idle processes per variant through `/proc/PID/smaps_rollup`; terminal-emulator memory is excluded. All measured zshard idle processes had zero child processes.

Oh My Zsh is pinned at `c0140703a53eb0d22be44f7bac318d0baacc927c` with the git plugin, robbyrussell theme and automatic updates disabled. The baseline does not add separate suggestion or highlighting plugins. Warm filesystem state, system load, distribution completion files and shell configuration affect these values.

[Raw samples and environment](benchmarks/release-0.1.1.json) include all startup, completion and memory samples.

## Reproduce

~~~sh
make check
python3 scripts/benchmark.py --samples 31 --output artifacts/benchmark.json
# Optional comparison against your reviewed, pinned upstream checkout:
python3 scripts/benchmark.py --samples 31 --omz /path/to/ohmyzsh --output artifacts/with-omz.json
~~~

## Runtime evidence

All 19 local checks passed on the release candidate. The tests use temporary homes and actual zsh PTYs. They cover suggestion acceptance, Tab completion, AI proposal staging without execution, JSON escaping, argument-preserving lazy loading, hook coexistence, themes, completion registration, pinned plugin integrity, unload, lock restoration, CLI warming with additional completion directories and a dedicated cache, secure dump reuse, and rejection of a writable dump. A Linux strace check verifies no child process is created by default startup or the built-in prompt.

The public HTTPS example-plugin path was exercised against commit `6ef55fe94dcf0f5f17c8f749041dc2cad6df0590`: install, verify, load, execute the hello command, unload, export, remove, restore and verify all succeeded. No downloaded plugin was loaded by the installation operation.

A benchmark exposed an earlier permission-mask bug that forced completion cache rebuilds. The fix uses an explicit base-8 mask and a new test proves a private warm dump is reused. The published samples come from the fixed source.

## Claims and review

| Review question | Evidence and boundary |
| --- | --- |
| What was created? | A zsh framework with a small default path and explicit extension APIs; zsh remains the shell. |
| Is the behavior clear? | Deferred initialization and feature-ready initialization have separate measurements; AI actions are explicit. |
| Are performance claims supported? | Raw samples, exact revisions and a reproducible script support this workstation comparison. |
| Is evaluation complete? | Linux zsh 5.9.2 and one workstation are validated. Other machines and plugin combinations need their own measurements. |
| Does the design uphold its boundaries? | PTY and process-trace checks cover no automatic command execution and no default child process; plugins remain trusted shell code. |
