#!/usr/bin/env python3
"""
Ollama Cloud cost/usage updater for the Omarchy top-bar plugin `ollama.cost`.

Ollama's accounting is exposed by three endpoints:

  GET  /api/usage?range=30d -> bucketed usage history. totals.usage_usd is the
                       metered USD value for the range and totals.request_count
                       the request count.
  GET  /api/balance -> the authoritative grant, spend and reset for the CURRENT
                       billing period:
                         included.allowance_usd  included credits (Pro = $60)
                         included.balance_usd    credits still remaining
                         included.period.{from,until}   period start / reset
                       Legacy plans instead return
                       included.{session,weekly}.{remaining_percent,resets_at}.
  POST /api/me      -> Plan ("free"|"pro"|"max"), Email, account ID

The balance endpoint is the source of truth for the meter AND the reset date:

  - Period-to-date cost = allowance_usd - balance_usd of the current period.
  - The period resets on a fixed day of the month (e.g. the 16th), NOT the 1st,
    so the label comes from the API rather than from day=1 arithmetic.
  - Requests are summed from the 30d usage buckets inside the current period.

If the grant is unknown the dollar scale is unknown: costs are reported as null
and the panel shows the raw fraction instead of inventing dollars.

Configuration (first match wins), all optional:
  OLLAMA_API_KEY / OLLAMA_KEY env, else
  ~/.config/ollama-cost/conf.json: {"api_key": "...", "monthly_credits": 60}
  ~/.config/ollama-cost/key        (single key on one line)
  HERMES_ENV (~/.hermes/.env)      OLLAMA_API_KEY=...   <- Hermes' own config

Output: $XDG_STATE_HOME/ollama-cost/overview.json (default ~/.local/state)
Stdlib only.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime

HOME = os.path.expanduser("~")
CONF_DIR = os.path.join(HOME, ".config", "ollama-cost")
CONF = os.path.join(CONF_DIR, "conf.json")
KEYFILE = os.path.join(CONF_DIR, "key")
HERMES_ENV = os.path.join(HOME, ".hermes", ".env")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"),
                         "ollama-cost")
OUT = os.path.join(STATE_DIR, "overview.json")
API = "https://ollama.com"
TIMEOUT = 25

# Included monthly usage credits per plan (ollama.com/pricing).
PLAN_CREDITS = {"free": 0.0, "starter": 0.0, "pro": 60.0, "max": 300.0, "team": 1000.0}


# --------------------------------------------------------------- configuration
def _read_env_file(path, names):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k.strip() in names:
                    out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def load_conf():
    conf = {}
    if os.path.exists(CONF):
        try:
            with open(CONF) as f:
                j = json.load(f)
            if isinstance(j, dict):
                conf = j
        except Exception:
            conf = {}
    return conf


def load_keys(conf):
    """All configured keys as [(label, key)] — conf.json first, then the env var.

    Several keys may belong to ONE Ollama account: /api/usage reports usage per
    ACCOUNT, not per key (verified — two keys on this account return byte-identical
    payloads), so the caller must de-dupe by account id rather than sum blindly.
    """
    out = []

    def add(label, k):
        k = (k or "").strip()
        if k and all(k != existing for _, existing in out):
            out.append((label, k))

    for name in ("OLLAMA_API_KEY", "OLLAMA_KEY"):
        if os.environ.get(name):
            add("env:" + name, os.environ[name])

    keys = conf.get("api_keys")
    if not isinstance(keys, list):
        keys = [conf["api_key"]] if conf.get("api_key") else []
    if not isinstance(keys, list):
        keys = []
    names = conf.get("names") if isinstance(conf.get("names"), list) else []
    for i, k in enumerate(keys):
        label = str(names[i]) if i < len(names) and names[i] else "key%d" % (i + 1)
        add(label, str(k))

    if conf.get("key"):
        add("conf:key", str(conf["key"]))
    if os.path.exists(KEYFILE):
        with open(KEYFILE) as f:
            add("key file", f.read())

    env = _read_env_file(HERMES_ENV, {"OLLAMA_API_KEY", "OLLAMA_KEY"})
    for name in ("OLLAMA_API_KEY", "OLLAMA_KEY"):
        if env.get(name):
            add("Hermes", env[name])
    return out


# --------------------------------------------------------------------- network
def fetch(key, path, method="GET", payload=None):
    headers = {"Authorization": "Bearer " + key, "Accept": "application/json",
               "User-Agent": "ollama-cost/1.0"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, method=method, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        body = r.read().decode()
    return json.loads(body) if body.strip() else {}


def num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def http_error(e):
    try:
        j = json.loads(e.read().decode())
        msg = (j.get("error") or {}).get("message") if isinstance(j.get("error"), dict) else j.get("error")
        return "%s: %s" % (e.code, msg or e.reason)
    except Exception:
        return "%s %s" % (e.code, getattr(e, "reason", "error"))


def usage_totals(u):
    """Metered USD and request count for a /api/usage response."""
    t = (u or {}).get("totals") or {}
    return {"cost": num(t.get("usage_usd")), "requests": int(num(t.get("request_count")))}


def requests_in_period(u, period_from):
    """Requests inside the billing period, summed from the day buckets.

    The 30d range usually starts before the period (which resets on a fixed day
    of the month), so summing only buckets at/after the period start avoids
    counting the previous period's traffic.
    """
    if period_from is None:
        return usage_totals(u)["requests"]
    total = 0
    for b in (u.get("buckets") or []):
        bfrom = parse_ts(b.get("from"))
        if bfrom is not None and bfrom >= period_from:
            total += int(num(b.get("request_count")))
    return total


def parse_ts(iso):
    try:
        return datetime.fromisoformat(iso)
    except (ValueError, TypeError):
        return None


def parse_balance(bal):
    """Grant, spend, balance and period from an /api/balance response.

    allowance/used/balance are None when unknown; period_from is a datetime and
    period_until the raw ISO string (or None). Legacy plans report a weekly
    remaining percentage instead of USD, mapped onto a grant of 100.
    """
    out = {"allowance": None, "used": None, "balance": None,
           "period_from": None, "period_until": None}
    included = bal.get("included") if isinstance(bal, dict) else None
    if isinstance(included, dict) and "allowance_usd" in included:
        out["allowance"] = num(included.get("allowance_usd"))
        if included.get("balance_usd") is not None:
            out["balance"] = num(included.get("balance_usd"))
            out["used"] = max(0.0, out["allowance"] - out["balance"])
        period = included.get("period") or {}
        out["period_from"] = parse_ts(period.get("from"))
        out["period_until"] = period.get("until")
    elif isinstance(included, dict):
        # Legacy plan: percentage limits per session/week, no USD grant.
        weekly = included.get("weekly") or {}
        if weekly:
            out["allowance"] = 100.0
            out["balance"] = num(weekly.get("remaining_percent"))
            out["used"] = max(0.0, out["allowance"] - out["balance"])
            out["period_until"] = weekly.get("resets_at")
    return out


# ------------------------------------------------------------------------ main
def main():
    conf = load_conf()
    keys = load_keys(conf)
    now = datetime.now().astimezone()

    if not keys:
        write({"error": "no-api-key", "updatedAt": now.isoformat(), "apiKeyConfigured": False})
        print("ollama-cost: no API key found (env / ~/.config/ollama-cost / ~/.hermes/.env)")
        return 1

    # /api/usage is ACCOUNT-wide, so keys sharing an account return identical
    # payloads. Fetch every key, then keep exactly one sample per account
    # (de-duped by the account id from /api/me) — summing would double-count.
    accounts = {}      # account id (or a fallback fingerprint) -> record
    errors = []
    key_labels = []

    for label, key in keys:
        try:
            u = fetch(key, "/api/usage?range=30d")
        except urllib.error.HTTPError as e:
            errors.append("%s: %s" % (label, http_error(e)))
            continue
        except Exception as e:
            errors.append("%s: %s" % (label, str(e)[:120]))
            continue

        plan = email = acct_id = None
        try:
            me = fetch(key, "/api/me", method="POST")   # GET is 405; POST with no body works
            plan = (me.get("Plan") or "").lower() or None
            email = me.get("Email")
            acct_id = me.get("ID") or None
        except Exception:
            pass

        # /api/balance is the source of truth for the grant, the spend and the
        # reset. Its absence (older server, network hiccup) degrades gracefully
        # to the metered 30d spend and the plan's nominal grant.
        try:
            bal = fetch(key, "/api/balance")
        except Exception:
            bal = {}
        pb = parse_balance(bal)
        allowance, used, balance_usd = pb["allowance"], pb["used"], pb["balance"]
        period_from, period_until = pb["period_from"], pb["period_until"]

        tot = usage_totals(u)
        if used is None:
            used = tot["cost"]
        if allowance is None:
            allowance = PLAN_CREDITS.get(plan or "", 0.0)
        if balance_usd is None:
            balance_usd = max(0.0, allowance - used)

        requests = requests_in_period(u, period_from)
        account_key = acct_id or ("anon:%s:%.5f:%s" % (plan, used, label))
        key_labels.append({"label": label, "account": acct_id or "unknown",
                           "plan": plan, "allowance": allowance, "used": used})

        if account_key in accounts:
            # Same account, different key: the numbers are duplicates by
            # definition. Keep the existing (better-labelled) sample.
            accounts[account_key]["otherKeys"].append(label)
            continue
        accounts[account_key] = {
            "plan": plan, "email": email,
            "allowance": allowance, "used": used, "balance": balance_usd,
            "periodFrom": period_from, "periodUntil": period_until,
            "requests": requests, "otherKeys": [], "label": label,
        }

    if not accounts:
        err = errors[0] if errors else "all keys returned no data"
        print("ollama-cost: no usable key: " + err)
        write({"error": err, "updatedAt": now.isoformat(), "apiKeyConfigured": True,
               "keyCount": len(keys), "keys": key_labels})
        return 1

    # Sum across DISTINCT accounts (each account's period is independent).
    allowance_total = round(sum(a["allowance"] for a in accounts.values()), 5)
    used_total = round(sum(a["used"] for a in accounts.values()), 5)
    balance_total = round(sum(a["balance"] for a in accounts.values()), 5)
    requests = sum(a["requests"] for a in accounts.values())

    primary = max(accounts.values(), key=lambda a: a["used"])
    plan = primary["plan"]
    email = primary["email"]
    period_from = primary["periodFrom"]
    period_until = primary["periodUntil"]

    credits = allowance_total
    if credits <= 0:
        credits = num(conf.get("monthly_credits"))
    if credits <= 0:
        credits = PLAN_CREDITS.get(plan or "", 0.0)

    # The meter is the fraction of the grant consumed this period. Used directly
    # for the limit bar; scaled by the grant for the dollar figures.
    meter = round(used_total / credits, 6) if credits > 0 else 0.0

    # Without a known grant there is no dollar scale, so costs stay null and the
    # panel falls back to showing the raw fraction of included credits.
    to_usd = (lambda frac: round(frac * credits, 5)) if credits > 0 else (lambda frac: None)
    month_cost = to_usd(meter)

    limit_rec = None
    if credits > 0:
        limit_rec = {
            "amount": credits, "used": used_total,
            "remaining": max(0.0, credits - used_total),
            "percent": round(min(100.0, meter * 100.0), 1),
            "reset": "periodic",
            "resetAt": period_until,
            "periodStart": period_from.isoformat() if period_from else None,
            "periodEnd": period_until,
            "usedFraction": meter,
            "reached": used_total >= credits,
        }

    rec = {
        "month": {"cost": month_cost, "fraction": meter, "partial": False,
                  "periodStart": period_from.date().isoformat() if period_from
                                 else ("%04d-%02d-01" % (now.year, now.month)),
                  "periodEnd": (period_until or "")[:10],
                  "resetAt": period_until},
        "balance": balance_total,
        "limit": limit_rec,
        "requests": requests,
        "plan": plan,
        "email": email,
        "accounts": len(accounts),
        "keys": len(keys),
        "keyInfo": key_labels,
        "keySource": ", ".join(sorted({label for label, _ in keys})),
        "updatedAt": now.isoformat(),
        "error": None,
        "apiKeyConfigured": True,
    }
    write(rec)
    print("ollama-cost: ok %d key(s) -> %d account(s) plan=%s meter=%.5f ($%s of $%s) requests=%d%s" % (
        len(keys), len(accounts), plan, meter,
        "?" if month_cost is None else "%.2f" % month_cost,
        "?" if credits <= 0 else "%.0f" % credits, requests,
        ("  ERRORS: " + "; ".join(errors)) if errors else ""))
    return 0 if not errors else 1


def write(rec):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f, indent=2)
    os.replace(tmp, OUT)


if __name__ == "__main__":
    sys.exit(main())
