#!/usr/bin/env python3
"""
nerdy-jokes: Random nerdy joke picker for Claude Code.
Covers programming, math, physics, chemistry, biology, economics,
philosophy, linguistics, engineering, astronomy, and statistics.

Usage:
  python3 joke.py                       # random joke
  python3 joke.py --lang zh             # random Chinese joke
  python3 joke.py --tag debugging       # joke about debugging
  python3 joke.py --tag physics --lang en  # English physics joke
  python3 joke.py --keyword vim         # search by keyword
  python3 joke.py --tags                # list all tags with counts
"""
import argparse
import json
import os
import random
import sys
from collections import Counter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
JOKES_PATH = os.path.join(SCRIPT_DIR, "..", "references", "jokes.json")

VALID_TAGS = [
    # dev
    "debugging", "languages", "tools", "devops", "work-culture",
    "databases", "algorithms", "security", "ai", "os",
    "frontend", "legacy", "networking",
    # science & academic
    "math", "physics", "chemistry", "biology", "astronomy",
    "statistics", "economics", "philosophy", "linguistics", "engineering",
    # fallback
    "general",
]


def load_jokes():
    with open(JOKES_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def filter_jokes(jokes, lang=None, tag=None, category=None, keyword=None):
    result = jokes
    if lang:
        result = [j for j in result if j["lang"] == lang]
    if tag:
        result = [j for j in result if tag in j.get("tags", [])]
    if category:
        result = [j for j in result if j["category"] == category]
    if keyword:
        kw = keyword.lower()
        result = [j for j in result if kw in j["content"].lower()]
    return result


def main():
    parser = argparse.ArgumentParser(description="Get a nerdy joke")
    parser.add_argument("--lang", choices=["en", "zh"], help="Language filter")
    parser.add_argument("--tag", choices=VALID_TAGS, help="Topic tag filter")
    parser.add_argument("--category", choices=["neutral", "chuck"], help="Category filter")
    parser.add_argument("--keyword", help="Keyword search in joke content")
    parser.add_argument("--tags", action="store_true", help="List all tags with counts")
    parser.add_argument("--all", action="store_true", help="Print all matching jokes")
    parser.add_argument("--count", action="store_true", help="Print count of matching jokes")
    args = parser.parse_args()

    jokes = load_jokes()

    if args.tags:
        tag_counts = Counter()
        for j in jokes:
            for t in j.get("tags", ["general"]):
                tag_counts[t] += 1
        for tag, count in sorted(tag_counts.items(), key=lambda x: -x[1]):
            print(f"  {tag:15s}: {count}")
        print(f"\n  Total jokes: {len(jokes)}")
        return

    filtered = filter_jokes(jokes, lang=args.lang, tag=args.tag,
                           category=args.category, keyword=args.keyword)

    if args.count:
        print(len(filtered))
        return

    if not filtered:
        if args.tag and args.lang:
            filtered = filter_jokes(jokes, lang=args.lang)
        if not filtered:
            filtered = jokes

    if args.all:
        for j in filtered:
            tags = ",".join(j.get("tags", []))
            print(f"[{j['lang']}|{tags}] {j['content']}")
    else:
        joke = random.choice(filtered)
        print(joke["content"])


if __name__ == "__main__":
    main()
