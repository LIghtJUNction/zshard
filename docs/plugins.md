# Configure and extend zshard

Set options before sourcing `zshard.zsh`. The framework can be sourced twice without registering duplicate hooks.

| Option | Default | Effect |
| --- | --- | --- |
| ZSHARD_KEYMAP | emacs | `vi` selects zsh's vi editor |
| ZSHARD_COMPLETION | lazy | `eager` initializes immediately; `off` leaves completion alone |
| ZSHARD_PROMPT | minimal | `off` leaves PROMPT and RPROMPT alone |
| ZSHARD_SUGGESTIONS | 1 | `0` disables history suggestions |
| ZSHARD_HISTORY_SCAN | 200 | Maximum history events inspected for a suggestion |
| ZSHARD_HIGHLIGHT | 1 | `0` disables command-token highlighting |
| ZSHARD_SHELL_INTEGRATION | 0 | `1` enables OSC 7 cwd and OSC 133 command boundaries |
| ZSHARD_CACHE_DIR | XDG_CACHE_HOME/zshard | Dedicated completion cache directory |
| ZSHARD_PLUGIN_DIR | XDG_DATA_HOME/zshard/plugins | Installed plugin checkouts and locks |
| HISTFILE | XDG_STATE_HOME/zshard/history | Existing user value is preserved |

XDG defaults follow the usual `~/.local/share`, `~/.local/state` and `~/.cache` locations. Completion uses a private cache directory and runs `compinit -i` for every new shell; insecure completion directories are skipped. It never uses `compinit -C` to bypass the audit. Dump files and compiled dumps must be owned by the current user, not symlinks, and not writable by group or others; unsafe caches are bypassed.


## Colors

One palette controls the prompt, command highlighting, history suggestions and
completion headings. Set these variables before sourcing `zshard.zsh`:

| Variable | Default | Purpose |
| --- | --- | --- |
| ZSHARD_COLOR_PATH | `#e8ded2` | Warm white directory label |
| ZSHARD_COLOR_ACCENT | `#d4a373` | Copper branch and prompt symbol |
| ZSHARD_COLOR_MUTED | `#a3978b` | Command duration |
| ZSHARD_COLOR_ERROR | `#e59a91` | Failed commands and unknown command tokens |
| ZSHARD_COLOR_COMMAND | `#e8ded2` | Recognized command tokens |
| ZSHARD_COLOR_KEYWORD | `#c5a4b6` | Shell keywords |
| ZSHARD_COLOR_SUGGESTION | `#a3978b` | History suggestion text |
| ZSHARD_COLOR_COMPLETION | `#d4a373` | Completion group descriptions |

Values use zsh color syntax: `default`, standard color names, palette indices
`0`–`255`, or `#RRGGBB`. The default RGB colors require a terminal with truecolor
support, including ztty. For an older terminal, set palette indices before loading
the framework. Custom prompt callbacks can use the same variables.

The prompt reads Git HEAD through zsh builtins. Changing directories refreshes
repository discovery; creating a repository in the current directory or removing
the cached checkout refreshes it before the next prompt. No Git process, file
watcher or network request runs as part of this refresh.

## Warm completion during installation

Run `zshard cache warm [COMPLETION_DIR ...]` from the standalone CLI or an existing shell to prepare the audited completion dump. Installers can call this after installing files, so the first interactive Tab uses the warm cache. This operation performs work explicitly during installation; normal startup still defers completion. Pass extra completion directories in the same order used by the interactive configuration. `ZSHARD_CACHE_DIR` can keep a suite cache separate. Added or removed completion files can require a later rebuild.

## Local loading

`zshard load FILE` sources the canonical file path once. `defer FILE` queues it for the next ZLE editing line. `lazy COMMAND FILE` installs a command wrapper, loads the file once when invoked, then forwards the original argument boundaries. A lazy plugin must define that command or make its external executable available.

Each deferred batch attempts every queued plugin once, even when another plugin fails. The batch returns its first nonzero status. Plugins queued while that batch runs wait for the next editing line. Failed plugins are not marked as loaded and are not retried automatically; after correcting a failure, use `zshard load FILE` to retry it explicitly. A failure does not undo shell changes already made by that plugin.

Plugins execute with the user's shell privileges. They are explicit trusted configuration. Startup does not search the network or load every installed plugin automatically.

## Pin a remote plugin

~~~zsh
zshard plugin add NAME HTTPS_OR_SSH_URL FULL_COMMIT_SHA RELATIVE_ENTRY_FILE
zshard plugin verify NAME
zshard use NAME
~~~

`NAME` allows letters, digits, underscores and hyphens. The Git commit must be the full 40-character SHA. An entry must resolve inside the checkout. Git file transports and repository hooks are disabled during installation. A checkout and its `.lock` file record the resolved pin. `verify` checks HEAD and uncommitted files with Git; this explicit integrity check is separate from shell loading.

Export exact pins for your dotfiles repository and restore them explicitly on another machine:

~~~zsh
zshard plugin export > plugins.lock
zshard plugin restore plugins.lock
~~~

Restore does not load code. It verifies matching installed checkouts, installs missing pins, and refuses a different existing pin. A failed batch keeps successfully installed entries so a retry can continue.

Change a pin by removing and reinstalling a reviewed version:

~~~zsh
zshard plugin remove NAME
zshard plugin add NAME URL NEW_FULL_COMMIT_SHA ENTRY
~~~

Removal affects files installed under the dedicated plugin directory. It does not undo functions already loaded into a running shell. Open a new shell or use the cleanup API.

## Hooks and cleanup

Use `zshard hook EVENT FUNCTION` and `zshard unhook EVENT FUNCTION`. Registration uses zsh's standard hook arrays and preserves other functions. Supported events are `chpwd`, `precmd`, `preexec`, `periodic`, `zshaddhistory`, `zshexit` and `zsh_directory_name`.

The [hello plugin](../examples/hello.plugin.zsh) is a usable template. Its cleanup function is `zshard_plugin_hello_unload`. A plugin named `my-tool` defines `zshard_plugin_my_tool_unload`. `zshard unload NAME` calls that function and clears the loaded-file record, so the plugin can be loaded again. It refuses to claim success when no cleanup function exists. A plugin owns and removes only its own hooks, variables, widgets and functions.

## Completion and themes

Before the first Tab, call `zshard completions DIRECTORY` to add a directory of standard zsh `_command` files. Use `#compdef command` in those files. Late registration returns an error instead of silently missing the completion.

Call `zshard theme FUNCTION` to use a prompt callback. The callback receives the last exit status and elapsed whole seconds, and assigns PROMPT and RPROMPT. The [compact theme](../examples/custom-theme.zsh) demonstrates this. Keep external commands out of prompt callbacks if you want the default latency contract.

ZLE integration uses `add-zle-hook-widget`. Its highlight entries carry a `memo=zshard` marker, so unrelated regions survive redraws. Suggestions yield when another widget owns POSTDISPLAY. Right and Ctrl-F accept a suggestion at the end of the buffer; otherwise they move forward normally. Repeated redraws reuse the previous history result, including an empty result, only while the input, history event and scan limit remain unchanged. Finishing an editing line drops that cache. Changed input still performs the bounded history search.

## AI contracts

`zai context` produces one `zshard.context.v1` JSON object. Its fields are `cwd`, `shell`, `shell_version`, `last_exit`, `capabilities`, `history_included` and `environment_included`. It does not read files or emit the previous command. In a fresh standalone process, `last_exit` starts at 0; the active interactive shell supplies its recorded previous status. The current directory can itself be private; sharing happens only when the user explicitly runs a provider or ssmcp.

`zai connect` forwards arguments to the actual `ssmcp` binary. It does not start a model. `ZSHARD_AI_COMMAND` must be an array; `zai ask` passes each element as an argv entry and sends context plus the request on stdin. It never evaluates strings as shell code.

`zai propose` requires an interactive TTY and one printable command line. It pushes text into the editing buffer. Review, edit or cancel it; only an explicit Enter runs the command.
