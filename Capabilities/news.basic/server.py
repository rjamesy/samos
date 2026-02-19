#!/usr/bin/env python3
"""Reference ToolPackage server for news.fetch (Phase 6)."""

import datetime as dt
import email.utils
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

DEFAULT_SOURCES = [
    ("Reuters", "https://www.reutersagency.com/feed/?best-topics=world&post_type=best"),
    ("BBC", "http://feeds.bbci.co.uk/news/world/rss.xml"),
    ("NYTimes", "https://rss.nytimes.com/services/xml/rss/nyt/World.xml"),
    ("The Guardian", "https://www.theguardian.com/world/rss"),
]


def normalize_title(title: str) -> str:
    cleaned = re.sub(r"[^a-z0-9\s]", " ", title.lower())
    return re.sub(r"\s+", " ", cleaned).strip()


def jaccard(a: str, b: str) -> float:
    ta = set(normalize_title(a).split())
    tb = set(normalize_title(b).split())
    if not ta or not tb:
        return 0.0
    inter = len(ta.intersection(tb))
    union = len(ta.union(tb))
    return inter / union if union else 0.0


def parse_date(raw: str):
    if not raw:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(raw)
        return parsed.astimezone(dt.timezone.utc)
    except Exception:
        pass
    try:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except Exception:
        return None


def fetch_feed(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "SamOS/news.basic"})
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = resp.read()
    root = ET.fromstring(data)
    out = []
    for item in root.findall(".//item") + root.findall(".//{http://www.w3.org/2005/Atom}entry"):
        title = (item.findtext("title") or item.findtext("{http://www.w3.org/2005/Atom}title") or "").strip()
        link = (item.findtext("link") or "").strip()
        if not link:
            atom_link = item.find("{http://www.w3.org/2005/Atom}link")
            if atom_link is not None:
                link = atom_link.attrib.get("href", "").strip()
        summary = (item.findtext("description") or item.findtext("{http://www.w3.org/2005/Atom}summary") or "").strip()
        published = (
            item.findtext("pubDate")
            or item.findtext("{http://www.w3.org/2005/Atom}published")
            or item.findtext("{http://www.w3.org/2005/Atom}updated")
            or ""
        ).strip()
        if title and link:
            out.append({"title": title, "url": link, "summary": summary or None, "published_at": published or None})
    return out


def news_fetch(args):
    query = (args.get("query") or "").strip().lower()
    max_items = max(1, min(int(args.get("max_items") or 15), 50))
    time_window_hours = max(1, min(int(args.get("time_window_hours") or 24), 168))
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=time_window_hours)

    rows = []
    for source_name, source_url in DEFAULT_SOURCES:
        try:
            for item in fetch_feed(source_url):
                title_summary = f'{item["title"]} {item.get("summary") or ""}'.lower()
                if query and query not in title_summary:
                    continue
                published_dt = parse_date(item.get("published_at"))
                if published_dt is not None and published_dt < cutoff:
                    continue
                rows.append(
                    {
                        "title": item["title"],
                        "source": source_name,
                        "published_at": item.get("published_at"),
                        "url": item["url"],
                        "summary": item.get("summary"),
                        "_published_dt": published_dt,
                    }
                )
        except Exception:
            continue

    deduped = []
    for row in rows:
        idx = next((i for i, existing in enumerate(deduped) if jaccard(existing["title"], row["title"]) >= 0.9), None)
        if idx is None:
            deduped.append(row)
            continue
        old = deduped[idx]
        if row["_published_dt"] and (not old["_published_dt"] or row["_published_dt"] > old["_published_dt"]):
            deduped[idx] = row

    deduped.sort(key=lambda r: (r["_published_dt"] is None, r["_published_dt"] or dt.datetime.min.replace(tzinfo=dt.timezone.utc)), reverse=False)
    deduped.reverse()
    trimmed = deduped[:max_items]
    for row in trimmed:
        row.pop("_published_dt", None)

    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "items": trimmed,
    }


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        print(json.dumps({"error": "missing input"}))
        return
    payload = json.loads(raw)
    tool = payload.get("tool")
    args = payload.get("args") or {}
    if tool != "news.fetch":
        print(json.dumps({"error": f"unknown tool {tool}"}))
        return
    print(json.dumps(news_fetch(args), ensure_ascii=True))


if __name__ == "__main__":
    main()
