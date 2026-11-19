#!/usr/bin/env python3
"""Bump only, or locally validate and atomically push a release commit and tag."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("part", choices=["major", "minor", "patch"])
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    if args.release and run("git", "status", "--porcelain", capture=True).strip():
        parser.error("release requires a clean working tree")
    current = (ROOT / "VERSION").read_text().strip()
    major, minor, patch = map(int, current.split("."))
    if args.part == "major":
        major, minor, patch = major + 1, 0, 0
    elif args.part == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    version = f"{major}.{minor}.{patch}"
    tag = "v" + version
    if args.release:
        tags = run("git", "tag", "--list", tag, capture=True)
        if tags.strip():
            parser.error(f"tag already exists: {tag}")
    entry = ROOT / "zshard.zsh"
    text = entry.read_text()
    replacement, count = re.subn(r"(?m)^typeset -g ZSHARD_VERSION=\d+\.\d+\.\d+$",
                                 f"typeset -g ZSHARD_VERSION={version}", text)
    if count != 1:
        parser.error("expected exactly one version declaration")
    (ROOT / "VERSION").write_text(version + "\n")
    entry.write_text(replacement)
    if args.release:
        run("make", "check")
        run("git", "add", "VERSION", "zshard.zsh")
        run("git", "commit", "-m", f"release: {tag}")
        run("git", "tag", "-a", tag, "-m", tag)
        run("git", "push", "--atomic", "origin", "HEAD", tag)
    print(version)


if __name__ == "__main__":
    main()
