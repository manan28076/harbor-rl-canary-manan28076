#!/usr/bin/env python3
"""Reconcile a CSV of payment transactions into a JSON summary."""
import csv
import json
import sys
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

STATUSES = {"SUCCESS", "FAILED", "PENDING"}


def parse_ts(raw):
    """Parse an ISO-8601 timestamp."""
    dt = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    return dt.replace(tzinfo=None)


def load_rows(path):
    """Read well-formed rows; malformed rows are skipped."""
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                rec = {
                    "tx_id": row["tx_id"].strip(),
                    "ts": parse_ts(row["timestamp"]),
                    "amount": Decimal(row["amount"].strip()),
                    "status": row["status"].strip().upper(),
                }
            except (KeyError, AttributeError, ValueError, InvalidOperation):
                continue
            if rec["tx_id"] and rec["amount"].is_finite() and rec["status"] in STATUSES:
                rows.append(rec)
    return rows


def rank(r):
    """Later timestamp wins."""
    return r["ts"]


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
        else:
            valid += 1
            total += r["amount"]
    total = total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {
        "total_valid_amount": float(total),
        "valid_count": valid,
        "failed_count": failed,
    }


def main():
    if len(sys.argv) < 1:
        print("usage: reconcile.py <transactions.csv>", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(summarize(load_rows(sys.argv[1]))))


if __name__ == "__main__":
    main()
