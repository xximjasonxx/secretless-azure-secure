from __future__ import annotations

import os
import random
import re
from typing import Any

from azure.identity import ManagedIdentityCredential
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from redis import Redis
from redis.exceptions import ResponseError

INDEX_NAME = "idx:assets"
KEY_PREFIX = "asset:"
SEED_COUNT = 120

app = FastAPI(title="Asset API", version="1.0.0")
redis_client: Redis | None = None


def get_env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def verify_api_key(x_api_key: str = Header(default="", alias="x-api-key")) -> None:
    configured_key = get_env("ASSET_API_KEY")
    if x_api_key != configured_key:
        raise HTTPException(status_code=401, detail="Invalid API key")


def build_client() -> Redis:
    host = get_env("REDIS_HOST")
    port = int(get_env("REDIS_PORT", "10000"))
    object_id = get_env("REDIS_OBJECT_ID")
    credential = ManagedIdentityCredential()
    token = credential.get_token("https://redis.azure.com/.default").token
    return Redis(
        host=host,
        port=port,
        ssl=True,
        decode_responses=True,
        username=object_id,
        password=token,
        socket_connect_timeout=5,
        socket_timeout=5,
    )


def ensure_index(client: Redis) -> None:
    try:
        client.execute_command(
            "FT.CREATE",
            INDEX_NAME,
            "ON",
            "HASH",
            "PREFIX",
            "1",
            KEY_PREFIX,
            "SCHEMA",
            "assetId",
            "TEXT",
            "SORTABLE",
            "name",
            "TEXT",
            "SORTABLE",
            "assetType",
            "TEXT",
            "SORTABLE",
            "site",
            "TEXT",
            "SORTABLE",
            "region",
            "TEXT",
            "SORTABLE",
            "status",
            "TEXT",
            "SORTABLE",
            "criticality",
            "TEXT",
            "SORTABLE",
            "feeder",
            "TEXT",
            "SORTABLE",
        )
    except ResponseError as exc:
        if "Index already exists" not in str(exc):
            raise


def build_seed_assets() -> list[dict[str, str]]:
    rng = random.Random(20260702)
    sites = [
        "North Substation",
        "South Substation",
        "East Substation",
        "West Substation",
        "Harbor Switching Yard",
        "River Bend Substation",
        "Pine Ridge Substation",
        "Metro Control Hub",
    ]
    asset_types = [
        "Transformer",
        "Circuit Breaker",
        "Switchgear",
        "Recloser",
        "Capacitor Bank",
        "Protection Relay",
        "Feeder Terminal",
    ]
    regions = ["North Grid", "South Grid", "East Grid", "West Grid", "Central Grid"]
    statuses = ["Operational", "Maintenance Window", "Inspection Due", "Degraded"]
    criticality = ["Low", "Medium", "High", "Critical"]
    feeders = [f"FD-{i:03d}" for i in range(101, 151)]

    assets: list[dict[str, str]] = []
    for i in range(1, SEED_COUNT + 1):
        asset_id = f"AST-{i:04d}"
        asset = {
            "assetId": asset_id,
            "name": f"{rng.choice(asset_types)} {rng.choice(['A', 'B', 'C', 'D'])}-{rng.randint(1, 80):02d}",
            "assetType": rng.choice(asset_types),
            "site": rng.choice(sites),
            "region": rng.choice(regions),
            "status": rng.choice(statuses),
            "criticality": rng.choice(criticality),
            "feeder": rng.choice(feeders),
        }
        assets.append(asset)
    return assets


def count_assets(client: Redis) -> int:
    raw = client.execute_command("FT.SEARCH", INDEX_NAME, "*", "LIMIT", "0", "0")
    return int(raw[0])


def seed_assets(client: Redis) -> int:
    existing = count_assets(client)
    if existing >= SEED_COUNT:
        return existing

    pipeline = client.pipeline(transaction=False)
    for asset in build_seed_assets():
        key = f"{KEY_PREFIX}{asset['assetId']}"
        pipeline.hset(key, mapping=asset)
    pipeline.execute()
    return count_assets(client)


def get_client() -> Redis:
    if redis_client is None:
        raise RuntimeError("Redis client is not initialized")
    return redis_client


def parse_search_result(raw: list[Any]) -> tuple[int, list[dict[str, str]]]:
    if not raw:
        return 0, []

    total = int(raw[0])
    items: list[dict[str, str]] = []
    for i in range(1, len(raw), 2):
        if i + 1 >= len(raw):
            break
        key = str(raw[i])
        flat_fields = raw[i + 1]
        fields: dict[str, str] = {}
        if isinstance(flat_fields, list):
            for j in range(0, len(flat_fields), 2):
                if j + 1 < len(flat_fields):
                    fields[str(flat_fields[j])] = str(flat_fields[j + 1])
        if "assetId" not in fields:
            fields["assetId"] = key.removeprefix(KEY_PREFIX)
        items.append(fields)
    return total, items


def to_redis_query(term: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9 _-]", " ", term).strip()
    if not cleaned:
        return "*"
    tokens = [t for t in cleaned.split(" ") if t]
    if not tokens:
        return "*"
    return " ".join(f"{token}*" for token in tokens)


@app.on_event("startup")
def startup() -> None:
    global redis_client
    redis_client = build_client()
    ensure_index(redis_client)
    seed_assets(redis_client)


@app.get("/health")
def health() -> dict[str, Any]:
    client = get_client()
    return {"status": "ok", "assetCount": count_assets(client)}


@app.get("/assets", dependencies=[Depends(verify_api_key)])
def list_assets(
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    client = get_client()
    raw = client.execute_command("FT.SEARCH", INDEX_NAME, "*", "LIMIT", str(offset), str(limit))
    total, items = parse_search_result(raw)
    return {"total": total, "items": items}


@app.get("/assets/search", dependencies=[Depends(verify_api_key)])
def search_assets(
    q: str = Query(..., min_length=1),
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    client = get_client()
    query = to_redis_query(q)
    raw = client.execute_command("FT.SEARCH", INDEX_NAME, query, "LIMIT", str(offset), str(limit))
    total, items = parse_search_result(raw)
    return {"query": q, "total": total, "items": items}


@app.get("/assets/{asset_id}", dependencies=[Depends(verify_api_key)])
def get_asset(asset_id: str) -> dict[str, Any]:
    client = get_client()
    key = f"{KEY_PREFIX}{asset_id}"
    fields = client.hgetall(key)
    if not fields:
        raise HTTPException(status_code=404, detail="Asset not found")
    return fields
