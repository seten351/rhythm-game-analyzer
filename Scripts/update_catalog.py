#!/usr/bin/env python3
"""Collect public song facts; validate all sources before atomically replacing the bundle.

Python 3.9+, standard library only. Never reads or writes the application's database.
The existing generated catalog doubles as the persistent external-ID ledger.
"""
import argparse
from collections import Counter
from datetime import date, datetime, timezone, timedelta
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import urljoin
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/OurNotesApp/Resources/our-notes-catalog.json"
SOURCE_ID = "our-notes-community"
DIFFICULTIES = ("EASY", "NORMAL", "HARD", "EXPERT")
URLS = {
    "gamerch": "https://gamerch.com/bang-dream-on/993622",
    "appmedia": "https://appmedia.jp/bang-dream-on/80416189",
    "wikiwiki": "https://wikiwiki.jp/on_database/楽曲一覧",
    "wikilist": "https://wikiwiki.jp/on_database/楽曲リスト",
    "schedule": "https://appmedia.jp/bang-dream-on/80429008",
}


class CatalogError(ValueError):
    pass


class TableParser(HTMLParser):
    """Read actual table rows, never sidebar text, comments, or embedded scripts."""
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.rows = []
        self.row = self.cell = self.link = None
        self.heading = ""
        self.in_heading = False
        self.ignored = 0
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("script", "style", "rt", "rp"):
            self.ignored += 1
        if tag == "h2":
            self.heading = ""
            self.in_heading = True
        if tag == "tr":
            self.row = {"attrs": attrs, "cells": [], "links": [], "heading": self.heading}
            self.cell = self.link = None
        if self.row is None:
            return
        if tag in ("td", "th"):
            self.cell = {"text": "", "links": []}
            self.row["cells"].append(self.cell)
        if tag == "a":
            self.link = {**attrs, "text": ""}
            self.row["links"].append(self.link)
            if self.cell is not None:
                self.cell["links"].append(self.link)
        if tag in ("br", "hr"):
            self.handle_data(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "rt", "rp"):
            self.ignored = max(0, self.ignored - 1)
        if tag == "h2":
            self.in_heading = False
        if tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = self.cell = self.link = None
        if tag in ("td", "th"):
            self.cell = None
        if tag == "a":
            self.link = None

    def handle_data(self, value):
        if self.ignored:
            return
        if self.in_heading:
            self.heading += value
        if self.cell is not None:
            self.cell["text"] += value
        if self.link is not None:
            self.link["text"] += value


def clean(value):
    # Gamerch's four alchemical symbols have UTF-8 bytes decoded as Latin-1.
    def repair(match):
        try:
            return match[0].encode("latin1").decode("utf-8")
        except (UnicodeError, ValueError):
            return match[0]
    return " ".join(re.sub(r"ð[\x80-\xff]{3}", repair, value).split())


def match_key(title):
    title = unicodedata.normalize("NFKC", clean(title))
    # Verified spelling error: Wiki* + Gamerch + the official theme-song announcement.
    title = title.replace("証明讃歌", "証命讃歌")
    title = title.translate(str.maketrans({"‘": "'", "’": "'", "‡": "†"}))
    title = "".join(c for c in unicodedata.normalize("NFD", title) if not unicodedata.combining(c))
    # Sources render the same four symbols as triangles/alchemical glyphs.
    symbol = re.fullmatch(r"Symbol\s+(I{1,3}|IV)\s*:\s*[△▽🜁🜂🜃🜄]", title, re.I)
    if symbol:
        return "symbol:" + symbol[1].upper()
    return "".join(title.casefold().split())


def parse_songs(name, source):
    result = {}
    for row in TableParser(source).rows:
        cells = row["cells"]
        values = [clean(c["text"]) for c in cells]
        text = " ".join(values)
        levels, extra = {}, {}
        if name == "appmedia" and "data-name" in row["attrs"]:
            title = row["attrs"]["data-name"]
            levels = {d.upper(): int(n) for d, n in re.findall(r"(Easy|Normal|Hard|Expert)\s*(\d+)", text)}
            link = cells[0]["links"][0]
            extra["band"] = row["attrs"]["data-band"]
            extra["genre"] = values[1]
        elif name == "gamerch" and len(cells) == 2 and "EASY" in text:
            title = values[0]
            levels = {d: int(n) for d, n in re.findall(r"(EASY|NORMAL|HARD|EXPERT)：(\d+)", text)}
            link = cells[0]["links"][0]
        elif name == "wikiwiki" and len(cells) == 5 and values[0].isdigit():
            title = values[3]
            link = cells[3]["links"][0]
            extra["type"] = values[4]
            extra["number"] = int(values[0])
        elif name == "wikilist" and len(cells) == 9 and cells[0]["links"] and re.fullmatch(r"\d{4}/\d{2}/\d{2}", values[8]):
            title = values[0]
            link = cells[0]["links"][0]
            for difficulty, level in zip(DIFFICULTIES, values[4:8]):
                if level:
                    if not level.isdigit():
                        raise CatalogError(f"{name}: invalid level for {title}: {level}")
                    levels[difficulty] = int(level)
            extra["releasedOn"] = values[8].replace("/", "-")
        else:
            continue
        key = match_key(title)
        if not key or key in result:
            raise CatalogError(f"{name}: empty or duplicate song: {title}")
        if name in ("appmedia", "gamerch") and set(levels) != set(DIFFICULTIES):
            raise CatalogError(f"{name}: missing difficulties: {title}")
        if any(not 1 <= n <= 50 for n in levels.values()):
            raise CatalogError(f"{name}: invalid levels: {title}")
        result[key] = {"title": clean(title), "url": urljoin(URLS[name], link["href"]), "levels": levels, **extra}
    # The release catalog already has 78 songs. Smaller output indicates a broken parser/page.
    if len(result) < 78:
        raise CatalogError(f"{name}: only {len(result)} songs; refusing incomplete page")
    if name == "wikiwiki" and sorted(s["number"] for s in result.values()) != list(range(1, len(result) + 1)):
        raise CatalogError("Wiki* song numbering is incomplete")
    return result


def parse_schedule(source):
    planned, released = {}, {}
    headings = {r["heading"] for r in TableParser(source).rows}
    if not {"楽曲追加予定まとめ", "楽曲追加履歴一覧"}.issubset(headings):
        raise CatalogError("Release schedule sections could not be read")
    for row in TableParser(source).rows:
        if "data-id" not in row["attrs"] or len(row["cells"]) != 3:
            continue
        title, _, when = [clean(c["text"]) for c in row["cells"]]
        match = re.fullmatch(r"(\d{4})年(\d{1,2})月(\d{1,2})日", when)
        released_on = date(*map(int, match.groups())).isoformat() if match else None
        record = {"title": title, "releasedOn": released_on, "url": URLS["schedule"]}
        if row["heading"] == "楽曲追加予定まとめ":
            planned[match_key(title)] = record
        elif row["heading"] == "楽曲追加履歴一覧":
            if released_on is None:
                raise CatalogError(f"Release date missing: {title}")
            released[match_key(title)] = record
    if len(released) < 6:
        raise CatalogError("Release history is missing known additions")
    return planned, released


def build_catalog(pages, previous, samples, as_of):
    tables = {name: parse_songs(name, pages[name]) for name in URLS if name != "schedule"}
    planned, released = parse_schedule(pages["schedule"])
    excluded = {key: row for key, row in planned.items() if key not in released}
    for table in tables.values():
        for key, row in table.items():
            if row.get("releasedOn", as_of) > as_of:
                excluded[key] = row
    for key, row in released.items():
        if row["releasedOn"] > as_of:
            excluded[key] = row
    active = {name: {k: v for k, v in table.items() if k not in excluded} for name, table in tables.items()}
    # Two independent current lists must agree on membership, including every dated addition.
    keys = set(active["wikiwiki"])
    if keys != set(active["appmedia"]):
        raise CatalogError("AppMedia / Wiki* membership differs: " + ", ".join(sorted(keys ^ set(active["appmedia"]))))
    others = set(active["gamerch"]) | set(active["wikilist"]) | {k for k, v in released.items() if v["releasedOn"] <= as_of}
    if others - keys:
        raise CatalogError("Other sources contain unaccounted songs: " + ", ".join(sorted(others - keys)))

    old_by_url = {}
    if previous:
        if previous["sourceId"] != SOURCE_ID or previous["formatVersion"] != 1:
            raise CatalogError("Existing catalog belongs to a different source/format")
        for song in previous["songs"]:
            for observation in song["observations"].values():
                url = observation["url"]
                if url in old_by_url and old_by_url[url]["id"] != song["id"]:
                    raise CatalogError("Ambiguous existing source URL")
                old_by_url[url] = song
    sample_by_key = {match_key(s["title"]): s for s in samples["songs"]}
    songs, conflicts = [], []
    for key in sorted(keys, key=lambda k: active["wikiwiki"][k]["number"]):
        observations = {name: table[key] for name, table in active.items() if key in table}
        matched = {old_by_url[o["url"]]["id"]: old_by_url[o["url"]] for o in observations.values() if o["url"] in old_by_url}
        if len(matched) > 1:
            raise CatalogError(f"Multiple existing IDs match {key}")
        prior = next(iter(matched.values()), None)
        seed = prior or sample_by_key.get(key)
        song_id = seed["id"] if seed else "song-" + str(uuid4())
        old_charts = {c["difficulty"]: c["id"] for c in seed["charts"]} if seed else {}
        title = active["wikiwiki"][key]["title"]
        if key.startswith("symbol:") and "gamerch" in observations:
            title = observations["gamerch"]["title"]
        aliases = sorted({o["title"] for o in observations.values()} - {title})
        charts = []
        for difficulty in DIFFICULTIES:
            # Wiki list and wiki index are one site; only wikilist has chart levels.
            votes = {name: o["levels"][difficulty] for name, o in observations.items() if difficulty in o["levels"]}
            counts = Counter(votes.values())
            if not counts:
                raise CatalogError(f"No level: {title} {difficulty}")
            level, count = counts.most_common(1)[0]
            if len(counts) > 1:
                if count <= len(votes) / 2:
                    raise CatalogError(f"Unresolved level conflict: {title} {difficulty}: {votes}")
                conflicts.append({"title": title, "difficulty": difficulty, "adopted": level, "reported": votes})
            charts.append({"id": old_charts.get(difficulty) or "chart-" + str(uuid4()), "difficulty": difficulty, "level": level, "status": "active"})
        if [c["level"] for c in charts] != sorted(c["level"] for c in charts):
            raise CatalogError(f"Difficulty levels are out of order: {title}")
        released_on = released.get(key, {}).get("releasedOn") or observations.get("wikilist", {}).get("releasedOn")
        if not released_on:
            raise CatalogError(f"No release date: {title}")
        songs.append({"id": song_id, "title": title, "aliases": aliases, "status": "active", "charts": charts,
                      "band": observations["appmedia"]["band"], "type": observations["wikiwiki"]["type"],
                      "releasedOn": released_on, "observations": observations})
    if previous and set(s["id"] for s in previous["songs"]) - set(s["id"] for s in songs):
        raise CatalogError("Previously published IDs disappeared; refusing to archive from a source omission")
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    document = {"formatVersion": 1, "gameId": "our-notes", "sourceId": SOURCE_ID,
                "revision": previous["revision"] + 1 if previous else 1, "generatedAt": now,
                "isComplete": True, "songs": songs,
                "verification": {"asOf": as_of, "sources": URLS, "sourceSongCounts": {k: len(v) for k, v in tables.items()},
                                 "levelConflicts": conflicts, "excludedScheduledSongs": list(excluded.values())}}
    validate_output(document)
    # A source check with unchanged content is a byte-for-byte no-op, not a new revision.
    if previous and previous["songs"] == songs and previous.get("verification") == document["verification"]:
        return previous
    return document


def validate_output(document):
    songs, charts = set(), set()
    for song in document["songs"]:
        if not song["title"] or song["id"] in songs:
            raise CatalogError("Duplicate ID or empty title")
        songs.add(song["id"])
        if [c["difficulty"] for c in song["charts"]] != list(DIFFICULTIES):
            raise CatalogError("Every song must contain four difficulties")
        for chart in song["charts"]:
            if chart["id"] in charts or not 1 <= chart["level"] <= 50:
                raise CatalogError("Duplicate chart ID or invalid level")
            charts.add(chart["id"])


def fetch(url):
    from urllib.parse import quote
    url = quote(url, safe=":/?=&%")
    result = subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--compressed",
                             "--max-time", "45", "--user-agent", "Mozilla/5.0", url], check=True, capture_output=True)
    text = result.stdout.decode("utf-8")
    if len(text) < 1000:
        raise CatalogError(f"Empty or truncated response: {url}")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--input-dir", type=Path, help="Read {source}.html snapshots instead of HTTP")
    parser.add_argument("--as-of", default=datetime.now(timezone(timedelta(hours=9))).date().isoformat())
    parser.add_argument("--check", action="store_true", help="Verify against published catalog without writing")
    args = parser.parse_args()
    date.fromisoformat(args.as_of)
    pages = {name: (args.input_dir / f"{name}.html").read_text(encoding="utf-8") if args.input_dir else fetch(url) for name, url in URLS.items()}
    previous = json.loads(args.output.read_text(encoding="utf-8")) if args.output.exists() else None
    samples = json.loads((OUTPUT.parent / "sample-catalog.json").read_text(encoding="utf-8"))
    document = build_catalog(pages, previous, samples, args.as_of)
    if args.check:
        if not previous or document["songs"] != previous["songs"] or document["verification"] != previous["verification"]:
            raise CatalogError("Published catalog differs from sources; run the updater")
    elif document != previous:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent, suffix=".tmp", delete=False) as handle:
                temporary = Path(handle.name)
                json.dump(document, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            temporary.replace(args.output)
        finally:
            if temporary and temporary.exists():
                temporary.unlink()
    print(json.dumps({"songs": len(document["songs"]), "charts": sum(len(s["charts"]) for s in document["songs"]),
                      "revision": document["revision"], **document["verification"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (CatalogError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Catalog update aborted; published file unchanged: {error}", file=sys.stderr)
        sys.exit(1)
