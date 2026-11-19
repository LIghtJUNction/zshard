#!/usr/bin/env python3
"""Reproducible process startup, completion and idle-memory measurements."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import random
import select
import shlex
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def summary(values):
    ordered = sorted(values)
    return {"median": round(statistics.median(values), 3),
            "p95": round(ordered[min(len(ordered) - 1, int(len(ordered) * .95))], 3),
            "min": round(min(values), 3), "max": round(max(values), 3),
            "samples": [round(x, 6) for x in values]}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def run_shell(script, env):
    return subprocess.run(["zsh", "-f", "-i", "-c", script], env=env, cwd=ROOT,
                          capture_output=True, text=True, timeout=20, check=True)


def idle_memory(script, env):
    process = subprocess.Popen(["zsh", "-f", "-i", "-c",
                                script + '; print -r -- __MEMORY_READY__; read -r waiting'],
                               env=env, cwd=ROOT, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([process.stdout], [], [], 15)
        if not ready or process.stdout.readline().strip() != "__MEMORY_READY__":
            raise RuntimeError("shell did not reach idle measurement point")
        rollup = Path(f"/proc/{process.pid}/smaps_rollup").read_text()
        fields = {}
        for line in rollup.splitlines():
            if line.startswith(("Rss:", "Pss:", "Private_Clean:", "Private_Dirty:")):
                key, value, _ = line.split()
                fields[key.rstrip(":").lower() + "_kib"] = int(value)
        children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
        fields["child_processes"] = len(children)
        return fields
    finally:
        process.communicate("\n", timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=31)
    parser.add_argument("--omz", type=Path, help="Existing reviewed oh-my-zsh checkout; no automatic download")
    parser.add_argument("--output", type=Path, default=Path("artifacts/benchmark.json"))
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("use at least five samples")
    with tempfile.TemporaryDirectory(prefix="zshard-benchmark-") as directory:
        base = Path(directory)
        variants = {
            "vanilla_zsh": ":",
            "zsh_with_compinit": 'autoload -Uz compinit; compinit -i -d "$XDG_CACHE_HOME/plain-zcompdump"',
            "zshard_startup": 'source "$ZSHARD_HOME/zshard.zsh"',
            "zshard_feature_ready": 'source "$ZSHARD_HOME/zshard.zsh"; zshard complete',
        }
        provenance = {}
        if args.omz:
            omz = args.omz.resolve()
            if not (omz / "oh-my-zsh.sh").is_file():
                parser.error("--omz must be an existing oh-my-zsh checkout")
            variants["oh_my_zsh_git_robbyrussell"] = (
                "ZSH=" + shlex.quote(str(omz)) + "; ZSH_THEME=robbyrussell; plugins=(git); "
                "zstyle ':omz:update' mode disabled; DISABLE_AUTO_UPDATE=true; "
                'ZSH_COMPDUMP="$XDG_CACHE_HOME/omz-zcompdump"; source "$ZSH/oh-my-zsh.sh"')
            provenance["oh_my_zsh"] = {
                "revision": subprocess.check_output(["git", "-C", str(omz), "rev-parse", "HEAD"], text=True).strip(),
                "configuration": "git plugin, robbyrussell theme, updates disabled",
                "additional_suggestion_highlighting_plugins": False,
            }
        envs = {}
        for name in variants:
            home = base / name
            (home / "cache").mkdir(parents=True)
            envs[name] = {"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8",
                          "HOME": str(home), "ZDOTDIR": str(home), "TERM": "xterm-256color",
                          "XDG_CACHE_HOME": str(home / "cache"), "XDG_DATA_HOME": str(home / "data"),
                          "XDG_STATE_HOME": str(home / "state"), "ZSHARD_HOME": str(ROOT)}
            for _ in range(3):
                run_shell(variants[name], envs[name])
        values = {name: [] for name in variants}
        rng = random.Random(0)
        for _ in range(args.samples):
            order = list(variants)
            rng.shuffle(order)
            for name in order:
                start = time.perf_counter_ns()
                run_shell(variants[name], envs[name])
                values[name].append((time.perf_counter_ns() - start) / 1_000_000)
        memory = {}
        if Path("/proc/self/smaps_rollup").exists():
            for name, script in variants.items():
                memory[name] = [idle_memory(script, envs[name]) for _ in range(5)]
        completion_script = (
            'source "$ZSHARD_HOME/zshard.zsh"; '
            'float began=$EPOCHREALTIME; zshard complete; '
            'print -r -- $(( (EPOCHREALTIME - began) * 1000.0 ))')
        warm = [float(run_shell(completion_script, envs["zshard_feature_ready"]).stdout)
                for _ in range(args.samples)]
        cold = []
        for index in range(5):
            env = dict(envs["zshard_feature_ready"], XDG_CACHE_HOME=str(base / f"cold-{index}"))
            cold.append(float(run_shell(completion_script, env).stdout))
        cpu = "unknown"
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
        result = {
            "schema": "zshard.benchmark.v1",
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "system": {"os": platform.system(), "kernel": platform.release(),
                       "arch": platform.machine(), "cpu": cpu, "load_average": os.getloadavg()},
            "zsh_version": subprocess.check_output(["zsh", "--version"], text=True).strip(),
            "framework": {"version": (ROOT / "VERSION").read_text().strip(),
                          "revision": git("rev-parse", "HEAD"),
                          "source_files": "zshard.zsh, lib/*.zsh"},
            "method": {"startup": "Wall clock of zsh -f -i -c setup; includes process launch and initialization, excludes first prompt rendering",
                       "sample_count": args.samples, "warmups": 3, "order": "seeded interleaving",
                       "state": "isolated empty HOME, warm completion dumps after warmups",
                       "memory": "Five idle zsh processes per variant; /proc/PID/smaps_rollup; no terminal emulator",
                       "completion": "Internal wall clock for the first compinit per process; warm or absent disk dump",
                       "comparison_limit": "The OMZ git baseline does not include extra autosuggestion or highlighting plugins; no universal speed ranking is claimed"},
            "provenance": provenance,
            "startup_ms": {name: summary(samples) for name, samples in values.items()},
            "first_completion_ms": {"warm_dump": summary(warm), "cold_dump": summary(cold)},
            "idle_memory": memory,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"startup_median_ms": {name: data["median"] for name, data in result["startup_ms"].items()},
                          "completion_median_ms": {name: data["median"] for name, data in result["first_completion_ms"].items()},
                          "idle_pss_median_kib": {name: statistics.median(row["pss_kib"] for row in rows) for name, rows in memory.items()},
                          "output": str(args.output)}, indent=2))


if __name__ == "__main__":
    main()
