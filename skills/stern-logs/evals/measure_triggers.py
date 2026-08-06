#!/usr/bin/env python3
"""Measure skill trigger rate without the partial-message early detection.

The skill-creator harness decides "did it trigger" from streaming
content_block deltas. With a thinking-enabled model that path misses the
Skill tool call entirely and reports every query as a non-trigger. This
reads completed assistant messages instead, which is the same thing the
harness's own fallback branch does — it just never gets there.

A skill counts as triggered if the Skill tool is invoked at any point in the
response, not only as the first tool call: consulting the skill after an
orienting command is still consulting the skill.
"""
import json
import os
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
COMMANDS = REPO / ".claude" / "commands"
MODEL = os.environ.get("EVAL_MODEL", "claude-opus-5")
TIMEOUT = int(os.environ.get("EVAL_TIMEOUT", "150"))


def parse_description(skill_dir: Path) -> tuple[str, str]:
    text = (skill_dir / "SKILL.md").read_text()
    fm = text.split("---")[1]
    name = [l for l in fm.splitlines() if l.startswith("name:")][0].split(":", 1)[1].strip()
    desc = fm.split("description:", 1)[1]
    desc = desc.split("\n---")[0].strip().lstrip(">-").strip()
    return name, " ".join(l.strip() for l in desc.splitlines()).strip()


def run_once(query: str, name: str, desc: str) -> dict:  # noqa: D401
    cid = f"{name}-skill-{uuid.uuid4().hex[:8]}"
    COMMANDS.mkdir(parents=True, exist_ok=True)
    cmd_file = COMMANDS / f"{cid}.md"
    indented = "\n  ".join(desc.splitlines())
    cmd_file.write_text(
        f"---\ndescription: |\n  {indented}\n---\n\n# {name}\n\nThis skill handles: {desc}\n"
    )
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    tools: list[str] = []
    triggered = False
    try:
        proc = subprocess.Popen(
            ["claude", "-p", query, "--output-format", "stream-json",
             "--verbose", "--model", MODEL],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            cwd=str(REPO), env=env, text=True,
        )
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = event.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    tool = block.get("name", "")
                    tools.append(tool)
                    inp = block.get("input", {})
                    # Match the injected-command prefix, not this run's exact id.
                    # Workers share .claude/commands/, so every concurrent run sees
                    # all eight files — identical descriptions under different random
                    # suffixes. Picking a sibling's copy still means the description
                    # triggered; exact-id matching scored those as misses.
                    if tool == "Skill" and str(inp.get("skill", "")).startswith(f"{name}-skill-"):
                        triggered = True
                if triggered:
                    break
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
    finally:
        cmd_file.unlink(missing_ok=True)
    return {"triggered": triggered, "tools": tools[:6]}


def main() -> int:
    skill_dir = REPO / "skills" / "stern-logs"
    spec = json.loads((Path(__file__).resolve().parent / "evals.json").read_text())
    eval_set = [{"query": e["prompt"], "should_trigger": e["should_trigger"]} for e in spec["evals"]]
    name, desc = parse_description(skill_dir)
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3

    jobs = [(i, r, item) for i, item in enumerate(eval_set) for r in range(runs)]
    print(f"{len(eval_set)} queries x {runs} runs = {len(jobs)} invocations", file=sys.stderr)

    results: dict[int, list[dict]] = {i: [] for i in range(len(eval_set))}
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {
            pool.submit(run_once, item["query"], name, desc): (i, item)
            for i, _r, item in jobs
        }
        for done, fut in enumerate(futures, 1):
            pass
        for fut, (i, _item) in futures.items():
            try:
                results[i].append(fut.result())
            except Exception as exc:  # noqa: BLE001
                results[i].append({"triggered": False, "tools": [], "error": str(exc)})
            print(".", end="", flush=True, file=sys.stderr)
    print(file=sys.stderr)

    out = []
    tp = fp = tn = fn = 0
    for i, item in enumerate(eval_set):
        rs = results[i]
        hits = sum(1 for r in rs if r["triggered"])
        rate = hits / len(rs)
        fired = rate >= 0.5
        if item["should_trigger"]:
            tp, fn = (tp + 1, fn) if fired else (tp, fn + 1)
        else:
            fp, tn = (fp + 1, tn) if fired else (fp, tn + 1)
        out.append({
            "query": item["query"],
            "should_trigger": item["should_trigger"],
            "hits": hits,
            "runs": len(rs),
            "rate": rate,
            "correct": fired == item["should_trigger"],
            "tools_seen": sorted({t for r in rs for t in r["tools"]}),
        })

    total = len(eval_set)
    recall = tp / (tp + fn) if tp + fn else 0.0
    precision = tp / (tp + fp) if tp + fp else 0.0
    summary = {
        "model": MODEL, "runs_per_query": runs,
        "accuracy": (tp + tn) / total, "precision": precision, "recall": recall,
        "true_positive": tp, "false_negative": fn,
        "false_positive": fp, "true_negative": tn,
    }
    dest = os.environ.get("EVAL_OUT")
    if dest:
        Path(dest).write_text(json.dumps({"summary": summary, "results": out}, indent=2, ensure_ascii=False))
    print(json.dumps({"summary": summary, "results": out}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
