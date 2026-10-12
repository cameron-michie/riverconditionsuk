"""Scene watcher: find new Sentinel-2 scenes over the UK, catalogue them, enqueue one job per scene."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import httpx
from shapely.geometry import box, mapping

from . import config


def search_new_scenes(client: httpx.Client, since: datetime) -> list[dict]:
    body = {
        "collections": [config.S2_COLLECTION],
        "bbox": list(config.UK_BBOX),
        "datetime": f"{since:%Y-%m-%dT%H:%M:%SZ}/..",
        "query": {"eo:cloud_cover": {"lt": config.MAX_CLOUD}},
        "limit": 200,
    }
    items, url = [], f"{config.STAC_URL}/search"
    while url:
        r = client.post(url, json=body, timeout=60)
        r.raise_for_status()
        j = r.json()
        items += j.get("features", [])
        nxt = next((l for l in j.get("links", []) if l.get("rel") == "next"), None)
        url, body = (nxt["href"], nxt.get("body", body)) if nxt else (None, body)
    return items


def register(conn, items: list[dict]) -> list[int]:
    """Upsert scenes; return ids of scenes not seen before (these get a job)."""
    new_ids = []
    with conn.cursor() as cur:
        for it in items:
            p = it["properties"]
            need = {k: it["assets"][v]["href"] for k, v in config.BANDS.items() if v in it["assets"]}
            if len(need) < len(config.BANDS):
                continue
            west, south, east, north = it["bbox"]
            cur.execute(
                """insert into core.scene (stac_id, collection, platform, tile, acquired_at, cloud_pct, bbox, assets)
                   values (%s,%s,%s,%s,%s,%s, st_geomfromgeojson(%s), %s)
                   on conflict (collection, stac_id) do nothing returning id""",
                (it["id"], it["collection"], p.get("platform"), p.get("grid:code") or p.get("s2:mgrs_tile"),
                 p["datetime"], p.get("eo:cloud_cover"), json.dumps(mapping(box(west, south, east, north))),
                 json.dumps(need)),
            )
            row = cur.fetchone()
            if row:
                new_ids.append(row[0])
                cur.execute("select pgmq.send(%s, %s::jsonb)", (config.QUEUE, json.dumps({"scene_id": row[0]})))
    conn.commit()
    return new_ids


def watch_once(conn) -> int:
    since = datetime.now(timezone.utc) - timedelta(days=config.LOOKBACK_DAYS)
    with httpx.Client() as client:
        items = search_new_scenes(client, since)
    return len(register(conn, items))
