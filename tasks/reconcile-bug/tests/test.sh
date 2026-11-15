#!/bin/bash
# Dense + hardened verifier for the reconcile-bug task.
#
# reward = 0.15*cli + 0.25*status + 0.10*(time + epoch + rank + bom + money + idcase)
#   cli    (0.15) Bug 1: wrong arg count -> `usage:` on stderr + exit 2, no traceback
#   status (0.25) Bug 2: SUCCESS / FAILED / PENDING handling (unique tx_ids)
#   Bug 3 = six independent input/dedupe sub-rules, 0.10 each (each uses its OWN isolated datasets):
#     time   timestamps compared as absolute instants (mixed UTC offsets, naive = UTC)
#     epoch  some upstream systems write timestamps as Unix epoch seconds
#     rank   a PENDING row never replaces a final (SUCCESS/FAILED) row, even if later
#     bom    the file starts with a UTF-8 BOM (spreadsheet export) and uses CRLF line endings
#     money  amounts like "$1,234.50", >2 decimals, each rounded half-up to cents BEFORE summing
#     idcase tx_id matching is case-insensitive and ignores surrounding spaces
#
# Anti-cheat:
#   * every dataset is generated at verify time with os-level randomness -> nothing to hardcode
#   * expected values come from the generator's own structured data, never from /app code
#   * each dataset is built so the specific wrong behaviour it targets changes the answer
#   * if two datasets with DIFFERENT expected answers produce the SAME non-trivial stdout, the script is
#     ignoring its input (hardcoded stub) -> total reward forced to 0.00
#   * fail closed: reward.txt starts at 0.00 and a verifier crash leaves it at 0.00
set -u
export APP_DIR="${APP_DIR:-/app}"
export LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
mkdir -p "$LOGS_DIR"
echo "0.00" > "$LOGS_DIR/reward.txt"

python3 - <<'PYEOF'
import csv, io, json, os, random, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

APP = os.environ["APP_DIR"]
LOGS = os.environ["LOGS_DIR"]
SCRIPT = os.path.join(APP, "reconcile.py")
WEIGHTS = {"cli": 0.15, "status": 0.25, "time": 0.10, "epoch": 0.10, "rank": 0.10, "bom": 0.10, "money": 0.10, "idcase": 0.10}
rng = random.SystemRandom()
DATA_DIR = os.path.join(LOGS, "data")
os.makedirs(DATA_DIR, exist_ok=True)
CENT = Decimal("0.01")
OFFSETS = ["Z", "+00:00", "+05:30", "-08:00", "+10:00", "-03:30", "+01:00", "naive"]
BASE = datetime(2026, 3, 1, tzinfo=timezone.utc)

# ------------------------------------------------------------------ small helpers
def fmt_ts(utc_dt, off):
    """Return (timestamp string, wall-clock datetime as written)."""
    if off == "epoch":
        return str(int(utc_dt.timestamp())), utc_dt
    if off == "naive":                           # no offset -> read as UTC
        return utc_dt.strftime("%Y-%m-%dT%H:%M:%S"), utc_dt
    if off == "Z":
        return utc_dt.strftime("%Y-%m-%dT%H:%M:%SZ"), utc_dt
    sign = 1 if off[0] == "+" else -1
    wall = utc_dt + sign * timedelta(hours=int(off[1:3]), minutes=int(off[4:6]))
    return wall.strftime("%Y-%m-%dT%H:%M:%S") + off, wall

def rand_amount():
    return Decimal(rng.randint(100, 900000)) / 100

def rand_instant(span_hours=48):
    return (BASE + timedelta(seconds=rng.randint(0, span_hours * 3600))).replace(second=0)

def new_ids(n):
    return [f"TX{i}" for i in rng.sample(range(100000, 999999), n)]

def to_bytes(rows, bom=False, crlf=False):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n" if crlf else "\n")
    w.writerow(["tx_id", "timestamp", "amount", "status"])
    for r in rows:
        w.writerow(r)
    data = buf.getvalue().encode("utf-8")
    return (b"\xef\xbb\xbf" + data) if bom else data

def totals(records):
    """records: dicts with status + amount (already the amount that should count)."""
    total, valid, failed = Decimal("0"), 0, 0
    for r in records:
        if r["status"] == "SUCCESS":
            valid += 1; total += r["amount"]
        elif r["status"] == "FAILED":
            failed += 1
    return {"total": float(total.quantize(CENT, rounding=ROUND_HALF_UP)), "valid_count": valid, "failed_count": failed}

def survivors(recs, key):
    """One record per group id: highest key wins (ties -> later row, because key ends with the row index)."""
    best = {}
    for r in recs:
        k = key(r)
        g = r["group"]
        if g not in best or k >= best[g][0]:
            best[g] = (k, r)
    return totals([v[1] for v in best.values()])

MALFORMED = lambda victim: [
    ["BAD1", "2026-03-01T10:00:00Z", "abc", "SUCCESS"], ["BAD2", "", "10.00", "SUCCESS"],
    ["", "2026-03-01T10:00:00Z", "10.00", "SUCCESS"], ["BAD3", "not-a-date", "10.00", "SUCCESS"],
    ["BAD4", "2026-03-01T10:00:00Z", "10.00", "REFUNDED"], ["BAD5", "2026-03-01T10:00:00Z"],
    [victim, "2027-01-01T00:00:00Z", "oops", "FAILED"],
]

# ------------------------------------------------------------------ dataset generators (each returns (bytes, expected))
def make_status():
    """Unique tx_ids, SUCCESS/FAILED/PENDING (odd casing/spaces). Isolates Bug 2."""
    while True:
        ids = new_ids(rng.randint(25, 40))
        rows, recs = [], []
        for tid in ids:
            st = rng.choices(["SUCCESS", "FAILED", "PENDING"], [4, 3, 3])[0]
            amt = rand_amount()
            ts, _ = fmt_ts(BASE + timedelta(seconds=rng.randint(0, 90 * 86400)), rng.choice(OFFSETS))
            rows.append([tid, ts, f"{amt}", rng.choice([st, st.lower(), st.title(), f" {st} "])])
            recs.append({"group": tid, "status": st, "amount": amt})
        cnt = {s: sum(r["status"] == s for r in recs) for s in ("SUCCESS", "FAILED", "PENDING")}
        if min(cnt.values()) >= 3:
            return to_bytes(rows), totals([r for r in recs])

def make_time():
    """Duplicates written in mixed UTC offsets / naive timestamps + malformed rows. Isolates 'time'."""
    for _ in range(300):
        items, ids = [], new_ids(rng.randint(12, 18))
        for tid in ids:
            insts = set()
            while len(insts) < rng.randint(1, 4):
                insts.add(rand_instant())
            for inst in insts:
                off = rng.choice(OFFSETS)
                ts, wall = fmt_ts(inst, off); amt = rand_amount(); st = rng.choice(["SUCCESS", "FAILED"])
                items.append(([tid, ts, f"{amt}", st],
                              {"group": tid, "status": st, "amount": amt, "inst": inst, "wall": wall, "epoch": off == "epoch"}))
        tie_id = new_ids(1)[0]; tie_inst = rand_instant()          # same instant, different offsets: later row wins
        for off, st in zip(rng.sample(["+05:30", "Z", "-08:00", "+10:00"], 2), ["SUCCESS", "FAILED"]):
            ts, wall = fmt_ts(tie_inst, off); amt = rand_amount()
            items.append(([tie_id, ts, f"{amt}", st],
                          {"group": tie_id, "status": st, "amount": amt, "inst": tie_inst, "wall": wall, "epoch": False}))
        rng.shuffle(items)
        for b in MALFORMED(rng.choice(ids)):
            items.insert(rng.randint(0, len(items)), (b, None))
        good = [(i, r) for i, (_, r) in enumerate(items) if r is not None]
        idx = {id(r): i for i, r in good}
        exp = survivors([r for _, r in good], lambda r: (r["inst"], idx[id(r)]))
        wrong_tz = survivors([r for _, r in good], lambda r: (r["wall"], idx[id(r)]))
        if exp != wrong_tz:
            return to_bytes([row for row, _ in items]), exp
    raise RuntimeError("time dataset")

def make_epoch():
    """Duplicates mixing ISO 'Z' timestamps and Unix epoch seconds. Isolates 'epoch'."""
    for _ in range(300):
        items = []
        for tid in new_ids(rng.randint(12, 18)):
            insts = set()
            while len(insts) < rng.randint(2, 4):
                insts.add(rand_instant())
            for inst in insts:
                off = rng.choice(["Z", "epoch"])
                ts, _ = fmt_ts(inst, off); amt = rand_amount(); st = rng.choice(["SUCCESS", "FAILED"])
                items.append(([tid, ts, f"{amt}", st],
                              {"group": tid, "status": st, "amount": amt, "inst": inst, "epoch": off == "epoch"}))
        rng.shuffle(items)
        for i, (_, r) in enumerate(items):
            r["i"] = i
        recs = [r for _, r in items]
        exp = survivors(recs, lambda r: (r["inst"], r["i"]))
        wrong = survivors([r for r in recs if not r["epoch"]], lambda r: (r["inst"], r["i"]))   # epoch rows skipped
        if exp != wrong:
            return to_bytes([row for row, _ in items]), exp
    raise RuntimeError("epoch dataset")

def make_rank():
    """Z timestamps only. Some tx_ids get a LATER PENDING retry after their final row. Isolates 'rank'."""
    for _ in range(300):
        items = []
        for tid in new_ids(rng.randint(12, 18)):
            insts = set()
            while len(insts) < rng.randint(1, 3):
                insts.add(rand_instant())
            for inst in insts:
                ts, _ = fmt_ts(inst, "Z"); amt = rand_amount(); st = rng.choice(["SUCCESS", "FAILED"])
                items.append(([tid, ts, f"{amt}", st], {"group": tid, "status": st, "amount": amt, "inst": inst}))
            if rng.random() < 0.6:
                inst = max(insts) + timedelta(minutes=rng.randint(5, 600)) if rng.random() < 0.8 else min(insts) - timedelta(minutes=30)
                ts, _ = fmt_ts(inst, "Z"); amt = rand_amount()
                items.append(([tid, ts, f"{amt}", "PENDING"], {"group": tid, "status": "PENDING", "amount": amt, "inst": inst}))
        rng.shuffle(items)
        idx = {id(r): i for i, (_, r) in enumerate(items)}
        recs = [r for _, r in items]
        exp = survivors(recs, lambda r: (r["status"] != "PENDING", r["inst"], idx[id(r)]))
        wrong = survivors(recs, lambda r: (r["inst"], idx[id(r)]))
        if exp != wrong:
            return to_bytes([row for row, _ in items]), exp
    raise RuntimeError("rank dataset")

def make_bom():
    """Plain unique rows, but the file starts with a UTF-8 BOM and uses CRLF line endings. Isolates 'bom'."""
    while True:
        rows, recs = [], []
        for tid in new_ids(rng.randint(15, 25)):
            st = rng.choice(["SUCCESS", "FAILED"]); amt = rand_amount()
            ts, _ = fmt_ts(rand_instant(), "Z")
            rows.append([tid, ts, f"{amt}", st]); recs.append({"group": tid, "status": st, "amount": amt})
        exp = totals(recs)
        if exp["valid_count"] >= 3 and exp["failed_count"] >= 3:
            return to_bytes(rows, bom=True, crlf=True), exp

def make_money():
    """Unique rows; amounts like "$1,234.50", 3-4 decimals and exact .xx5 ties. Isolates 'money'."""
    for _ in range(300):
        rows, eff, raw_recs, fmt_only = [], [], [], []
        for tid in new_ids(rng.randint(18, 26)):
            st = rng.choices(["SUCCESS", "FAILED"], [7, 3])[0]
            d = rng.choice([2, 2, 3, 4])
            raw = Decimal(rng.randint(1, 3000000)) / (Decimal(10) ** d)
            if rng.random() < 0.25:
                raw = Decimal(rng.randint(1, 99999)) / 100 + Decimal("0.005")     # exact tie, must round UP
            s = format(raw, "f")
            if raw >= 1000 and rng.random() < 0.6:
                s = format(raw, ",f")
            if rng.random() < 0.4:
                s = "$" + s
            q = raw.quantize(CENT, rounding=ROUND_HALF_UP)
            ts, _ = fmt_ts(rand_instant(), "Z")
            rows.append([tid, ts, s, st])
            eff.append({"group": tid, "status": st, "amount": q})
            raw_recs.append({"group": tid, "status": st, "amount": raw})
            fmt_only.append(("$" in s or "," in s))
        exp = totals(eff)
        no_round = totals(raw_recs)                                    # sum first, round once at the end
        no_format = totals([r for r, f in zip(eff, fmt_only) if not f])  # $ / comma rows treated as malformed
        if exp != no_round and exp != no_format:
            return to_bytes(rows), exp
    raise RuntimeError("money dataset")

def make_idcase():
    """Same transaction written as TX123 / tx123 / ' Tx123 '. Z timestamps, plain amounts. Isolates 'idcase'."""
    for _ in range(300):
        items = []
        for tid in new_ids(rng.randint(10, 14)):
            insts = set()
            while len(insts) < rng.randint(2, 4):
                insts.add(rand_instant())
            for inst in insts:
                ts, _ = fmt_ts(inst, "Z"); amt = rand_amount(); st = rng.choice(["SUCCESS", "FAILED"])
                raw_id = rng.choice([tid, tid.lower(), f" {tid} ", "Tx" + tid[2:]])
                items.append(([raw_id, ts, f"{amt}", st],
                              {"group": tid, "raw": raw_id.strip(), "status": st, "amount": amt, "inst": inst}))
        rng.shuffle(items)
        for i, (_, r) in enumerate(items):
            r["i"] = i
        recs = [r for _, r in items]
        exp = survivors(recs, lambda r: (r["inst"], r["i"]))
        wrong = survivors([{**r, "group": r["raw"]} for r in recs], lambda r: (r["inst"], r["i"]))
        if exp != wrong:
            return to_bytes([row for row, _ in items]), exp
    raise RuntimeError("idcase dataset")

# ------------------------------------------------------------------ running + comparing
def run(args):
    try:
        p = subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True,
                           timeout=20, cwd=tempfile.gettempdir())
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return -1, "", repr(e)

def matches(stdout, exp):
    try:
        out = json.loads(stdout)
        if not isinstance(out, dict) or set(out) != {"total_valid_amount", "valid_count", "failed_count"}:
            return False
        for k in ("valid_count", "failed_count"):
            if type(out[k]) is not int or out[k] != exp[k]:
                return False
        t = out["total_valid_amount"]
        return type(t) in (int, float) and abs(t - exp["total"]) < 0.005
    except Exception:
        return False

def write_dataset(name, data):
    path = os.path.join(DATA_DIR, name)
    with open(path, "wb") as f:
        f.write(data)
    return path

results, outputs = {}, []          # outputs: (expected, stdout) pairs for the anti-cheat invariant

def two(gen, name):
    """Run on two independent random datasets; both must match."""
    ok = True
    for i in range(2):
        data, exp = gen()
        rc, out, _ = run([write_dataset(f"{name}_{i}.csv", data)])
        outputs.append((exp, out))
        ok = ok and rc == 0 and matches(out, exp)
    return ok

# check 1: CLI contract
sample, _ = make_status()
p1 = write_dataset("cli_sample.csv", sample)
rc0, _, err0 = run([])
rc2, _, err2 = run([p1, "extra-arg"])
results["cli"] = (rc0 == 2 and "usage" in err0.lower() and "Traceback" not in err0
                  and rc2 == 2 and "Traceback" not in err2)
# checks 2-7
results["status"] = two(make_status, "status")
results["time"] = two(make_time, "time")
results["epoch"] = two(make_epoch, "epoch")
results["rank"] = two(make_rank, "rank")
results["bom"] = two(make_bom, "bom")
results["money"] = two(make_money, "money")
results["idcase"] = two(make_idcase, "idcase")

# anti-cheat: the SAME non-trivial answer printed for datasets whose correct answers differ => the script
# ignores its input (a hardcoded stub). All-zero output is NOT flagged: an honest-but-broken script that skips
# every row (e.g. cannot read a BOM header) legitimately prints zeros and simply fails those checks.
def nontrivial(stdout):
    try:
        o = json.loads(stdout)
        return bool(o.get("valid_count") or o.get("failed_count") or o.get("total_valid_amount"))
    except Exception:
        return False

cheat = False
for a in range(len(outputs)):
    for b in range(a + 1, len(outputs)):
        if outputs[a][0] != outputs[b][0] and outputs[a][1] == outputs[b][1] and nontrivial(outputs[a][1]):
            cheat = True

score = 0.0 if cheat else round(sum(WEIGHTS[k] for k, v in results.items() if v), 2)
with open(os.path.join(LOGS, "reward.txt"), "w") as f:
    f.write(f"{score:.2f}\n")
with open(os.path.join(LOGS, "breakdown.json"), "w") as f:
    json.dump({"checks": results, "weights": WEIGHTS, "cheat_detected": cheat, "reward": score}, f, indent=2)
print(json.dumps({"checks": results, "cheat_detected": cheat, "reward": score}))
PYEOF
