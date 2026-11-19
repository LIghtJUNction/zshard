#!/usr/bin/env python3
"""Explain native compinit cache decisions without reading user configuration."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="zshard-cache-diagnostic-") as tmp:
        env = {**os.environ, "HOME": tmp, "ZDOTDIR": tmp, "HISTFILE": "/dev/null",
               "XDG_CACHE_HOME": tmp + "/cache", "XDG_STATE_HOME": tmp + "/state",
               "ZSHARD_CACHE_DIR": tmp + "/cache/zshard", "ZSHARD_HOME": str(ROOT)}
        def shell(code):
            return subprocess.run(["zsh", "-f", "-i", "-c",
                                   'source "$ZSHARD_HOME/zshard.zsh"; ' + code],
                                  env=env, capture_output=True, text=True, check=True)
        shell("zshard complete")
        dump = next((Path(tmp) / "cache/zshard").glob("zcompdump-*"))
        header = dump.read_text().splitlines()[0]
        with dump.open("a") as output:
            output.write("\ntypeset -g ZSHARD_DIAGNOSTIC_CACHE=yes\n")
        dump.chmod(0o600)
        probe = shell(
            'functions[_zshard_audited_compinit]=${functions[_zshard_audited_compinit]//compinit -i/compinit -i -w}; '
            '_zshard_cache_usable "$ZSHARD_CACHE_DIR" "$ZSHARD_CACHE_DIR/zcompdump-$ZSH_VERSION"; '
            'print -r -- "cache_guard=$?"; zshard complete; '
            'print -r -- "reused=${ZSHARD_DIAGNOSTIC_CACHE:-no}"'
        )
        print(json.dumps({"native_dump_header": header, "probe": probe.stdout.splitlines(),
                          "native_compinit_reason": probe.stderr.splitlines()}, indent=2))


if __name__ == "__main__":
    main()
