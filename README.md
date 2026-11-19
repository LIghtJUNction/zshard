# zshard

A small zsh framework for Project Z. Completion, history suggestions, command highlighting, a warm copper prompt, and explicit AI handoff fit in ordinary zsh scripts.

Part of [oh-my-ztty](https://github.com/LIghtJUNction/oh-my-ztty). Use it on its own with zsh 5.9 or newer:

~~~zsh
git clone https://github.com/LIghtJUNction/zshard.git ~/.local/share/zshard
source ~/.local/share/zshard/zshard.zsh
~~~

Add that source line to your zsh configuration when ready. Remove the line to uninstall the framework; configuration and history remain yours. The complete suite provides managed installation and removal.

## The shell stays small

The prompt reads Git's HEAD directly. Its palette is shared with command highlights, suggestions and completion headings; [all eight colors can be configured](docs/plugins.md#colors). It shows the directory, branch, exit status and slow-command duration. There is no prompt subprocess, network request, background watcher or required icon font. A real process trace tests that contract.

Completion initializes on the first Tab, with zsh's security audit. [Cache validation](docs/completion-cache.md) checks the current completion inputs and audit exclusions before reusing a dump. History suggestions inspect a bounded recent window; Right or Ctrl-F accepts the text. Highlighting recognizes the first command token. This is a small editor integration, not a full shell grammar checker.

~~~zsh
# Set before source:
ZSHARD_KEYMAP=vi            # default: emacs
ZSHARD_COMPLETION=eager     # default: lazy; also supports off
ZSHARD_SHELL_INTEGRATION=1  # optional OSC 7 / OSC 133
source ~/.local/share/zshard/zshard.zsh
~~~

See [configuration and extension APIs](docs/plugins.md) and the [measured release results](docs/performance.md). Startup, first completion, memory and comparison measurements are reproducible with [the benchmark script](scripts/benchmark.py). Faster startup partly comes from deferring completion; compare the feature-ready results as well.

## Add only the plugins you want

~~~zsh
zshard load ~/.config/zsh/my-plugin.zsh
zshard defer ~/.config/zsh/after-prompt.zsh
zshard lazy expensive-command ~/.config/zsh/tool-init.zsh
~~~

Remote plugins require a full commit SHA and an explicit entry file. Installation never sources downloaded code. Review a plugin, install its pin, then load it with `zshard use NAME`. The [complete example](examples/hello.plugin.zsh) includes a command, a hook and cleanup.

## AI is an explicit action

~~~zsh
zai context                      # local JSON: directory, shell, last exit
zai connect                      # run Project Z ssmcp here
zai propose 'git status --short'  # stage text for review; Enter runs it
~~~

Context excludes environment variables, history and file contents. No model or account is configured implicitly. For an existing provider CLI, configure an argv array and run `zai ask`:

~~~zsh
ZSHARD_AI_COMMAND=(my-provider-cli --read-stdin)
zai ask 'Explain this directory context'
~~~

That command receives the context and request on stdin. Provider output is displayed; it is never evaluated. `bin/zshard ai context` also works outside an interactive shell.

## Develop

~~~sh
make check
make bench
python3 scripts/bump.py patch --release
~~~

`make check` runs isolated runtime and PTY checks. Benchmarking is separate. The release command tests locally, commits the version, tags it, and pushes an atomic release update. GitHub Actions builds a source archive and checksums on release tags; routine checks are manual.

MIT licensed. zshard adds no compiled helper or Rust standard-library dependency. It uses the system zsh runtime; ssmcp remains a separately installed Project Z companion.
