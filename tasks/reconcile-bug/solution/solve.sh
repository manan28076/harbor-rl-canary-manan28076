#!/bin/bash
# Reference solution: replaces /app/reconcile.py with the version that fixes all bugs.
cat > /app/reconcile.py <<'PYEOF'
#!/usr/bin/env python3
"""Reconcile a CSV of payment transactions into a JSON summary."""
import csv
import json
import sys
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

STATUSES = {"SUCCESS", "FAILED", "PENDING"}


def parse_ts(raw):
    """Parse an ISO-8601 string or Unix epoch seconds into an aware UTC datetime."""
    raw = raw.strip()
    if raw.isdigit():
        return datetime.fromtimestamp(int(raw), tz=timezone.utc)
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_amount(raw):
    """'$1,234.5678' -> Decimal rounded half-up to cents; not finite -> ValueError."""
    amount = Decimal(raw.strip().lstrip("$").replace(",", ""))
    if not amount.is_finite():
        raise ValueError("not finite")
    return amount.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def load_rows(path):
    """Read well-formed rows; malformed rows are skipped."""
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            try:
                rec = {
                    "tx_id": row["tx_id"].strip().upper(),
                    "ts": parse_ts(row["timestamp"]),
                    "amount": parse_amount(row["amount"]),
                    "status": row["status"].strip().upper(),
                }
            except (KeyError, AttributeError, ValueError, InvalidOperation):
                continue
            if rec["tx_id"] and rec["amount"].is_finite() and rec["status"] in STATUSES:
                rows.append(rec)
    return rows


def rank(r):
    """A final status outranks PENDING; otherwise the later instant wins."""
    return (r["status"] != "PENDING", r["ts"])


def dedupe(rows):
    """Keep one record per tx_id (ties: the later row in the file)."""
    best = {}
    for r in rows:
        cur = best.get(r["tx_id"])
        if cur is None or rank(r) >= rank(cur):
            best[r["tx_id"]] = r
    return list(best.values())


def summarize(rows):
    total, valid, failed = Decimal("0"), 0, 0
    for r in dedupe(rows):
        if r["status"] == "FAILED":
            failed += 1
        elif r["status"] == "SUCCESS":
            valid += 1
            total += r["amount"]
    total = total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {
        "total_valid_amount": float(total),
        "valid_count": valid,
        "failed_count": failed,
    }


def main():
    if len(sys.argv) != 2:
        print("usage: reconcile.py <transactions.csv>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(summarize(load_rows(sys.argv[1]))))


if __name__ == "__main__":
    main()
PYEOF
echo "Done!"
