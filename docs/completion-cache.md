# Completion cache compatibility

zshard 0.1.2 keeps the native zsh security audit on every completion initialization. It adds a small compatibility layer around cache generation and invalidation; it does not use `compinit -C`, change users' `fpath`, or disable permission checks.

## Why the cache needed more than a file count

The zsh 5.9 functions [compinit](https://github.com/zsh-users/zsh/blob/zsh-5.9/Completion/compinit), [compaudit](https://github.com/zsh-users/zsh/blob/zsh-5.9/Completion/compaudit) and [compdump](https://github.com/zsh-users/zsh/blob/zsh-5.9/Completion/compdump) do not always derive the same count after rejecting completion paths. Their treatment of symlinks and permitted private groups also differs. A stable set of inputs can therefore regenerate an identical dump on every shell launch.

A stock Ubuntu 24.04 container with zsh 5.9-6ubuntu2 reproduced this with a foreign-owned completion directory: compinit compared 968 candidates with a dump recording 966. The patched candidate reused its corrected dump without changing either its hash or nanosecond modification time. Separate fixtures cover a safe symlink and an allowed private-group directory alongside a rejected world-writable directory.

Counts also miss changes that preserve the total. In an isolated root fixture, two previously owned completion files changed to another UID. A native warm dump retained both executable mappings. Another fixture replaced one completion file with another while keeping the total unchanged. zshard now rebuilds in both cases.

## What changes during initialization

The scoped audit wrapper calls the original `compaudit` and observes its ordered directory and candidate lists plus rejected paths. These inputs become an escaped signature in a comment inside the dump. The signature is compared as data and is never evaluated. A literal line feed or carriage return in the encoded signature disables disk caching for that initialization; tests also cover real filenames containing both characters.

When the signature differs, native `compinit -i` builds at a new private staging path. The scoped dump wrapper retains compinit's actual candidate count and writes the signature beside the header. The complete file is published atomically, so its metadata and completion definitions cannot come from different concurrent writers. A stale compiled dump is removed before publication. Failed metadata writes or publication return failure; both original functions are restored and staging files are removed.

When inputs and audit exclusions match, native `compinit -i` performs its usual audit and loads the warm dump. File additions, same-count replacements, changed rejected paths and different completion directories invalidate it. As with native compinit, editing a `#compdef` line without changing the file list requires explicitly rebuilding the dump.

## Evidence and reproduction

[Ubuntu fixture results](benchmarks/completion-cache-ubuntu-24.04.json) preserve the baseline and patched traces. [Runtime tests](../tests/test_runtime.py) cover reuse, unsafe ownership changes, equal-count replacements, line-safe metadata, function restoration and write failure. The formal release workflow runs the ownership-transition test with an isolated temporary home as root.

~~~sh
make check
python3 scripts/diagnose_completion.py
# The ownership test needs an isolated root container; it never uses real dotfiles.
docker run --rm -v "$PWD:/src:ro" -w /src ubuntu:24.04 \
  bash -ceu 'apt-get update >/dev/null
    apt-get install -y zsh python3 >/dev/null
    python3 tests/test_runtime.py RuntimeTests.test_changed_completion_file_ownership_invalidates_cache'
~~~

The extra signature work occurs when completion first initializes, including explicit `zshard cache warm`. Default startup and prompt rendering still create no child process. See [measured timings](performance.md) for the resulting first-completion cost.
