#!/usr/bin/env python3
"""Programmatic grader for nerdy-jokes Iron Law regression tests.

Runs each assertion in evals.json against the `response.txt` produced in
an eval workspace, and writes `grading.json` per run.

Usage:
    python3 evals/grader.py <workspace_iteration_dir> evals/evals.json

Example (from skill root):
    python3 evals/grader.py ../nerdy-jokes-workspace/iteration-1 evals/evals.json

Expects the workspace layout:
    <workspace>/eval-<id>-<name>/{with_skill,without_skill}/outputs/response.txt
"""
import json
import re
import sys
from pathlib import Path

ANNOUNCE_PATTERNS = [
    r"讓我(說|講|來|給)(個|你)?笑話",
    r"來個?笑話",
    r"說個笑話",
    r"here('?s| is)? a (nerdy )?joke",
    r"let me (tell|share) (you )?a joke",
    r"how about this (one|joke)",
    r"try this (one|joke)",
]

EXPLAIN_PATTERNS = [
    r"這個笑話的意思",
    r"笑點在於",
    r"梗是",
    r"this (joke )?(works|is funny) because",
    r"the punchline is",
    r"the joke is that",
    r"get it\?",
]

CJK = re.compile(r"[\u4e00-\u9fff]")


def non_blockquote_text(text: str) -> str:
    """Return the prose outside blockquotes (and code fences).

    Announcement/explanation checks must not inspect the joke itself: a joke's
    own wording can legitimately contain phrases like "the punchline is", which
    would otherwise be a false positive.
    """
    lines = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or stripped.startswith(">"):
            continue
        lines.append(line)
    return "\n".join(lines)


def blockquote_groups(text: str) -> list[str]:
    """Return consecutive blockquote groups joined."""
    groups = []
    current = []
    in_fence = False
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            if current:
                groups.append(" ".join(current))
                current = []
            continue
        if in_fence:
            continue
        if stripped.startswith(">"):
            content = stripped.lstrip("> ").rstrip()
            if content:
                current.append(content)
        else:
            if current:
                groups.append(" ".join(current))
                current = []
    if current:
        groups.append(" ".join(current))
    return groups


def grade(assertion_id: str, text: str) -> tuple[bool, str]:
    groups = blockquote_groups(text)
    quoted = " ".join(groups)
    prose = non_blockquote_text(text)

    if assertion_id == "joke_delivered":
        ok = len(groups) >= 1
        return ok, f"found {len(groups)} blockquote group(s)"

    if assertion_id == "language_zh":
        if not groups:
            return False, "no blockquote to check"
        has_cjk = bool(CJK.search(quoted))
        return has_cjk, f"blockquote CJK={has_cjk}, content={quoted[:80]!r}"

    if assertion_id == "language_en":
        if not groups:
            return False, "no blockquote to check"
        has_cjk = bool(CJK.search(quoted))
        return not has_cjk, f"blockquote has CJK={has_cjk}, content={quoted[:80]!r}"

    if assertion_id == "no_announcement":
        for pat in ANNOUNCE_PATTERNS:
            m = re.search(pat, prose, re.IGNORECASE)
            if m:
                return False, f"matched announcement: {m.group(0)!r}"
        return True, "no announcement phrase found"

    if assertion_id == "no_explanation":
        for pat in EXPLAIN_PATTERNS:
            m = re.search(pat, prose, re.IGNORECASE)
            if m:
                return False, f"matched explanation: {m.group(0)!r}"
        return True, "no explanation phrase found"

    if assertion_id == "single_joke":
        ok = len(groups) <= 1
        return ok, f"blockquote groups = {len(groups)}"

    if assertion_id == "no_joke_when_frustrated":
        ok = len(groups) == 0
        return ok, f"blockquote groups = {len(groups)} (expected 0)"

    if assertion_id == "addresses_bug":
        keywords = ["async", "await", "context", "bug", "debug", "非同步", "錯誤", "排查", "log"]
        hits = [k for k in keywords if k.lower() in text.lower()]
        ok = len(text) > 200 and len(hits) >= 2
        return ok, f"len={len(text)}, keyword hits={hits}"

    return False, f"unknown assertion: {assertion_id}"


def main():
    workspace = Path(sys.argv[1])
    evals_file = Path(sys.argv[2])
    evals = json.loads(evals_file.read_text())["evals"]

    for ev in evals:
        eval_name = ev["name"]
        eval_dir = workspace / f"eval-{ev['id']}-{eval_name}"
        for config in ["with_skill", "without_skill"]:
            run_dir = eval_dir / config
            response_file = run_dir / "outputs" / "response.txt"
            if not response_file.exists():
                print(f"SKIP missing: {response_file}")
                continue
            text = response_file.read_text()
            results = []
            for a in ev["assertions"]:
                passed, evidence = grade(a["id"], text)
                results.append({
                    "text": a["desc"],
                    "passed": passed,
                    "evidence": evidence,
                })
            grading = {
                "eval_id": ev["id"],
                "eval_name": eval_name,
                "config": config,
                "expectations": results,
                "summary": {
                    "total": len(results),
                    "passed": sum(1 for r in results if r["passed"]),
                },
            }
            (run_dir / "grading.json").write_text(json.dumps(grading, indent=2, ensure_ascii=False))
            print(f"{eval_name:30s} {config:15s} {grading['summary']['passed']}/{grading['summary']['total']}")


if __name__ == "__main__":
    main()
