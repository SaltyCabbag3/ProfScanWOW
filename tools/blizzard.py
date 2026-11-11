"""Minimal client for Blizzard's Web API, World of Warcraft: Forever auction houses.

Forever's endpoints are undocumented (mapped by the community in November 2026,
see https://us.forums.blizzard.com/en/blizzard/t/60334):
    /data/wow/ruleset/{ruleset}/auctions/                       houses: { auctions: [{ id, name, key }] }
    /data/wow/ruleset/{ruleset}/auctions/{house}                { id, name, auctions: [...], ... }
    /data/wow/ruleset/{ruleset}/auctions/{house}/commodities    { auctions: [{ id, item, quantity, unit_price, time_left }] }
all on namespace dynamic-forever-{region}. Every ruleset currently returns the
same houses, so one ruleset is enough. Blizzard refreshes the data about hourly.

Credentials: a client ID and secret from https://develop.battle.net/access/clients,
kept in a JSON file (see profscan_db.py api-setup) or in the environment
variables BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET.
"""
import base64
import gzip
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from email.utils import parsedate_to_datetime

TOKEN_URL = "https://oauth.battle.net/token"


class ApiError(RuntimeError):
    pass


class Client:
    def __init__(self, client_id, client_secret, region="eu", ruleset=1):
        self.client_id, self.client_secret = client_id, client_secret
        self.region, self.ruleset = region, ruleset
        self._token, self._token_expires = None, 0

    @classmethod
    def from_config(cls, path, ruleset=1):
        cfg = {}
        if path.exists():
            cfg = json.loads(path.read_text(encoding="utf-8"))
        client_id = os.environ.get("BLIZZARD_CLIENT_ID") or cfg.get("client_id")
        secret = os.environ.get("BLIZZARD_CLIENT_SECRET") or cfg.get("client_secret")
        if not (client_id and secret):
            raise ApiError(f"No Blizzard API credentials. Run: python profscan_db.py api-setup  (writes {path})")
        return cls(client_id, secret, cfg.get("region", "eu"), cfg.get("ruleset", ruleset))

    def token(self):
        if self._token and time.time() < self._token_expires - 60:
            return self._token
        auth = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        req = urllib.request.Request(TOKEN_URL, data=b"grant_type=client_credentials",
                                     headers={"Authorization": f"Basic {auth}",
                                              "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.loads(r.read())
        except urllib.error.HTTPError as e:
            raise ApiError(f"Blizzard rejected the credentials (HTTP {e.code}). Check the client ID and secret.") from None
        self._token, self._token_expires = data["access_token"], time.time() + data.get("expires_in", 3600)
        return self._token

    def get(self, path, if_modified_since=None):
        """GET a dynamic-forever path. Returns (json or None if unchanged, last_modified unix time or None)."""
        query = urllib.parse.urlencode({"namespace": f"dynamic-forever-{self.region}", "locale": "en_US"})
        url = f"https://{self.region}.api.blizzard.com{path}?{query}"
        headers = {"Authorization": f"Bearer {self.token()}", "Accept-Encoding": "gzip"}
        if if_modified_since:
            headers["If-Modified-Since"] = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(if_modified_since))
        for attempt in range(4):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
                    body = r.read()
                    if r.headers.get("Content-Encoding") == "gzip":
                        body = gzip.decompress(body)
                    modified = r.headers.get("Last-Modified")
                    return json.loads(body), int(parsedate_to_datetime(modified).timestamp()) if modified else None
            except urllib.error.HTTPError as e:
                if e.code == 304:
                    return None, if_modified_since
                if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(2 ** attempt * 2)
                    continue
                raise ApiError(f"HTTP {e.code} for {path}") from None
        raise ApiError(f"giving up on {path}")

    # Forever auction houses --------------------------------------------------------------

    def houses(self):
        data, _ = self.get(f"/data/wow/ruleset/{self.ruleset}/auctions/")
        return [{"id": h["id"], "name": h.get("name") or f"house {h['id']}"} for h in data.get("auctions", [])]

    def listings(self, house, if_modified_since=None):
        """All listings of a house: (list of dicts, last_modified), or (None, ...) if unchanged.
        Each listing: id, item, quantity, unit_price (copper per item), time_left, commodity."""
        base = f"/data/wow/ruleset/{self.ruleset}/auctions/{house}"
        commodities, modified = self.get(base + "/commodities", if_modified_since)
        if commodities is None:
            return None, modified
        items, modified_items = self.get(base)
        out = []
        for a in commodities.get("auctions", []):
            out.append({"id": a["id"], "item": a["item"]["id"], "quantity": a["quantity"],
                        "unit_price": a["unit_price"], "time_left": a.get("time_left"), "commodity": True})
        for a in (items or {}).get("auctions") or []:
            if not a.get("buyout"):
                continue  # bid-only: no price to compare
            q = max(1, a.get("quantity", 1))
            out.append({"id": a["id"], "item": a["item"]["id"], "quantity": q, "unit_price": a["buyout"] // q,
                        "time_left": a.get("time_left"), "commodity": False})
        return out, max(m for m in (modified, modified_items) if m) if (modified or modified_items) else None
