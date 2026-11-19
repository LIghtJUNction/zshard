#!/usr/bin/env python3
"""Compare real first-prompt delivery and in-process hooks against a local ref."""
import argparse
from datetime import datetime, timezone
import fcntl
import io
import json
import os
from pathlib import Path
import platform
import pty
import random
import select
import statistics
import struct
import subprocess
import tarfile
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
MARKER = b"__ZSHARD_BENCHMARK_READY__"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def summarize(values):
    ordered = sorted(values)
    return {"median": round(statistics.median(values), 4),
            "p95": round(ordered[min(len(ordered) - 1, int(len(ordered) * .95))], 4),
            "samples": [round(value, 6) for value in values]}


def first_prompt(env, cwd):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    process = None
    try:
        began = time.perf_counter_ns()
        process = subprocess.Popen(["zsh", "-d", "-i"], cwd=cwd, env=env,
                                   stdin=slave, stdout=slave, stderr=slave,
                                   start_new_session=True)
        os.close(slave)
        slave = None
        output = b""
        deadline = time.monotonic() + 10
        while MARKER not in output:
            ready, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise RuntimeError("first prompt timed out: " + repr(output[-2000:]))
            block = os.read(master, 65536)
            if not block:
                raise RuntimeError("shell exited before first prompt")
            output += block
        return (time.perf_counter_ns() - began) / 1_000_000
    finally:
        if slave is not None:
            os.close(slave)
        if process is not None and process.poll() is None:
            try:
                os.write(master, b"\x03exit\n")
                process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                process.kill()
                process.wait(timeout=2)
        os.close(master)


def hook_batch(env, cwd, kind, count):
    before = 'source "$ZSHARD_HOME/zshard.zsh" || exit $?; '
    if kind.startswith("redraw"):
        before += ('fc -R "$HOME/benchmark-history"; BUFFER=missing_command_for_benchmark; '
                   'CURSOR=$#BUFFER; ')
        call = ("BUFFER=missing_command_$iteration; CURSOR=$#BUFFER; _zshard_redraw"
                if kind == "redraw_changing" else "_zshard_redraw")
    elif kind == "custom_prompt":
        before += ("_benchmark_theme() { PROMPT='%~ %# '; }; "
                   "zshard theme _benchmark_theme; ")
        call = "_zshard_precmd"
    else:
        call = "_zshard_precmd"
    command = (before + "integer iteration; float began=$EPOCHREALTIME; "
               + "for (( iteration=0; iteration<" + str(count) + "; ++iteration )); do "
               + call + "; done; "
               + "print -r -- $(( (EPOCHREALTIME - began) * 1000.0 / " + str(count) + " ))")
    result = subprocess.run(["zsh", "-d", "-f", "-i", "-c", command], cwd=cwd, env=env,
                            capture_output=True, text=True, timeout=20, check=True)
    return float(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Existing local Git commit or tag")
    parser.add_argument("--samples", type=int, default=31)
    parser.add_argument("--iterations", type=int, default=300)
    parser.add_argument("--output", type=Path, default=Path("artifacts/interaction.json"))
    args = parser.parse_args()
    if args.samples < 5 or args.iterations < 10:
        parser.error("use at least five samples and ten hook iterations")
    baseline_sha = git("rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}")
    current_sha = git("rev-parse", "HEAD")
    with tempfile.TemporaryDirectory(prefix="zshard-interaction-") as directory:
        base = Path(directory)
        baseline = base / "baseline-source"
        baseline.mkdir()
        archive = subprocess.check_output(["git", "archive", baseline_sha], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(baseline, filter="data")
        repository = base / "repository"
        subprocess.run(["git", "init", "-q", "--initial-branch=main", str(repository)], check=True)
        outside = base / "outside" / "nested"
        outside.mkdir(parents=True)
        variants = {"baseline": baseline, "current": ROOT}
        environments = {}
        for name, source in variants.items():
            home = base / name
            home.mkdir()
            (home / ".zshrc").write_text(
                'source "$ZSHARD_HOME/zshard.zsh" || exit $?\n'
                '_benchmark_ready() { PROMPT+="__ZSHARD_BENCHMARK_READY__"; }\n'
                'precmd_functions+=(_benchmark_ready)\n')
            (home / "benchmark-history").write_text(
                "".join("print history-entry-" + str(i) + "\n" for i in range(250)))
            environments[name] = {
                "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8", "TERM": "xterm-256color",
                "HOME": str(home), "ZDOTDIR": str(home), "ZSHARD_HOME": str(source),
                "XDG_STATE_HOME": str(home / "state"), "XDG_CACHE_HOME": str(home / "cache"),
                "XDG_DATA_HOME": str(home / "data"),
            }
        cases = {
            "first_prompt": lambda env: first_prompt(env, repository),
            "prompt_repository": lambda env: hook_batch(env, repository, "prompt", args.iterations),
            "prompt_outside_repository": lambda env: hook_batch(env, outside, "prompt", args.iterations),
            "custom_prompt": lambda env: hook_batch(env, repository, "custom_prompt", args.iterations),
            "redraw_same_buffer_miss": lambda env: hook_batch(env, repository, "redraw", args.iterations),
            "redraw_changing_buffer_miss": lambda env: hook_batch(env, repository, "redraw_changing", args.iterations),
        }
        samples = {name: {case: [] for case in cases} for name in variants}
        for env in environments.values():
            for _ in range(3):
                for measure in cases.values():
                    measure(env)
        rng = random.Random(0)
        for _ in range(args.samples):
            order = [(name, case) for name in variants for case in cases]
            rng.shuffle(order)
            for name, case in order:
                samples[name][case].append(cases[case](environments[name]))
        result = {
            "schema": "zshard.interaction-benchmark.v1",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "system": {"os": platform.system(), "arch": platform.machine(),
                       "kernel": platform.release(), "load_average": os.getloadavg()},
            "zsh_version": subprocess.check_output(["zsh", "--version"], text=True).strip(),
            "source": {"baseline": baseline_sha, "current": current_sha,
                       "current_tracked_diff": git("diff", "--stat", "HEAD")},
            "method": {
                "samples": args.samples, "warmups": 3, "order": "seeded interleaving",
                "first_prompt": "zsh -d -i launch to final marker in the rendered prompt in a 100x24 real PTY; isolated HOME; completion remains deferred",
                "hooks": "Internal EPOCHREALTIME per call, averaged over " + str(args.iterations) + " calls; includes loop overhead; no terminal painting",
                "redraw": "250 imported history entries, scan bounded to default 200, no match; unchanged-buffer and changing-buffer batches measured separately",
                "custom_prompt": "Identical callback in both sources; builds a compact path prompt",
                "limitations": "One shared workstation, warm filesystem, no universal ranking; first Tab and memory are measured separately by scripts/benchmark.py",
            },
            "milliseconds": {name: {case: summarize(values) for case, values in data.items()}
                             for name, data in samples.items()},
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({name: {case: values["median"] for case, values in data.items()}
                          for name, data in result["milliseconds"].items()}, indent=2))


if __name__ == "__main__":
    main()
