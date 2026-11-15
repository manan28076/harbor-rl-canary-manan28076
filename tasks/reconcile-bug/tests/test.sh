#!/bin/bash
# Dense + hardened verifier for the reconcile-bug task.
#
# Reward = 0.20*cli + 0.30*status + 0.50*dedupe   (each check is independent)
#   cli    : wrong arg count -> usage on stderr + exit code 2 (no traceback)
#   status : SUCCESS/FAILED/PENDING handling on two RANDOM unique-tx_id datasets
#   dedupe : one record per tx_id (absolute instants incl. epoch secs; PENDING never replaces a final row) on two RANDOM datasets
#
# Anti-cheat:
#   * every dataset is generated at verify time with os-level randomness -> no fixed answer to hardcode
#   * expected values come from the generator's own structured data, never from /app code
#   * if two datasets with DIFFERENT expected answers produce IDENTICAL stdout, the script is
#     ignoring its input -> total reward forced to 0.00
#   * fail closed: reward.txt starts at 0.00 and a verifier crash leaves it at 0.00
set -u
export APP_DIR="${APP_DIR:-/app}"
export LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
mkdir -p "$LOGS_DIR"
echo "0.00" > "$LOGS_DIR/reward.txt"

python3 - <<'PYEOF'
import json, os, random, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

APP = os.environ["APP_DIR"]
LOGS = os.environ["LOGS_DIR"]
SCRIPT = os.path.join(APP, "reconcile.py")
WEIGHTS = {"cli": 0.20, "status": 0.30, "dedupe": 0.50}
rng = random.SystemRandom()
DATA_DIR = os.path.join(LOGS, "data")
os.makedirs(DATA_DIR, exist_ok=True)

# ------------------------------------------------------------------ data generators
OFFSETS = ["Z", "+00:00", "+05:30", "-08:00", "+10:00", "-03:30", "+01:00", "naive"]

def fmt_ts(utc_dt, off):
    """Return (timestamp string, wall-clock datetime as written)."""
    if off == "epoch":                       # Unix epoch seconds -> UTC
        return str(int(utc_dt.timestamp())), utc_dt
    if off == "naive":                       # no offset -> must be read as UTC
        return utc_dt.strftime("%Y-%m-%dT%H:%M:%S"), utc_dt
    if off == "Z":
        return utc_dt.strftime("%Y-%m-%dT%H:%M:%SZ"), utc_dt
    sign = 1 if off[0] == "+" else -1
    delta = sign * timedelta(hours=int(off[1:3]), minutes=int(off[4:6]))
    wall = utc_dt + delta
    return wall.strftime("%Y-%m-%dT%H:%M:%S") + off, wall

def rand_amount():
    return Decimal(rng.randint(100, 900000)) / 100

def rand_instant(base, span_hours):
    return base + timedelta(seconds=rng.randint(0, span_hours * 3600))

def expected_from(records):
    """records: dicts with tx_id, key (sortable), status, amount. Latest key wins."""
    latest = {}
    for r in records:
        cur = latest.get(r["tx_id"])
        if cur is None or r["key"] >= cur["key"]:
            latest[r["tx_id"]] = r
    total, valid, failed = Decimal("0"), 0, 0
    for r in latest.values():
        if r["status"] == "SUCCESS":
            valid += 1; total += r["amount"]
        elif r["status"] == "FAILED":
            failed += 1
    total = total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {"total": float(total), "valid_count": valid, "failed_count": failed}

def disguise(status):
    return rng.choice([status, status.lower(), status.title(), f" {status} "])

def make_status_dataset():
    """Unique tx_ids, mixed SUCCESS/FAILED/PENDING, mixed offsets. No duplicates -> isolates the status rule."""
    while True:
        n = rng.randint(25, 40)
        ids = rng.sample(range(100000, 999999), n)
        base = datetime(2026, 1, 1, tzinfo=timezone.utc)
        lines, recs = [], []
        for i, tid in enumerate(ids):
            st = rng.choices(["SUCCESS", "FAILED", "PENDING"], [4, 3, 3])[0]
            amt = rand_amount()
            ts, _ = fmt_ts(rand_instant(base, 24 * 90), rng.choice(OFFSETS))
            lines.append(f"TX{tid},{ts},{amt},{disguise(st)}")
            recs.append({"tx_id": f"TX{tid}", "key": i, "status": st, "amount": amt})
        pend = sum(1 for r in recs if r["status"] == "PENDING")
        succ = sum(1 for r in recs if r["status"] == "SUCCESS")
        fail = sum(1 for r in recs if r["status"] == "FAILED")
        if pend >= 3 and succ >= 3 and fail >= 3:
            return "tx_id,timestamp,amount,status\n" + "\n".join(lines) + "\n", expected_from(recs)

def survivors(good, tz_ok=True, epoch_ok=True, rule_c=True):
    """Expected answer, optionally simulating ONE specific wrong implementation."""
    recs = []
    for i, r in good:
        if r["epoch"] and not epoch_ok:          # epoch timestamps treated as malformed
            continue
        t = r["inst"] if tz_ok else r["wall"]    # wall-clock instead of absolute instant
        final = (r["status"] != "PENDING") if rule_c else True
        recs.append({**r, "key": (final, t, i)})
    return expected_from(recs)

def make_dedupe_dataset():
    """Duplicate tx_ids across timezones / epoch seconds, later PENDING rows, malformed rows.
    No PENDING-only tx_id exists, so the status rule cannot influence this check.
    Each of the three sub-rules (absolute instants, epoch seconds, PENDING never supersedes
    a final row) must change the answer, so fixing only some of them cannot pass."""
    for _ in range(300):
        base = datetime(2026, 3, 1, tzinfo=timezone.utc)
        rows = []  # (line, record-or-None)
        n_tx = rng.randint(12, 18)
        ids = rng.sample(range(100000, 999999), n_tx)
        for tid in ids:
            k = rng.randint(1, 4)
            instants = set()
            while len(instants) < k:
                instants.add(rand_instant(base, 48).replace(second=0))
            for inst in instants:
                off = rng.choice(OFFSETS + ["epoch", "epoch"])
                ts, wall = fmt_ts(inst, off)
                st, amt = rng.choice(["SUCCESS", "FAILED"]), rand_amount()
                rows.append((f"TX{tid},{ts},{amt},{st}",
                             {"tx_id": f"TX{tid}", "inst": inst, "wall": wall, "status": st,
                              "amount": amt, "epoch": off == "epoch"}))
            if rng.random() < 0.45:              # a PENDING retry logged AFTER every final row
                inst = max(instants) + timedelta(minutes=rng.randint(5, 600))
                off = rng.choice(OFFSETS + ["epoch"])
                ts, wall = fmt_ts(inst, off); amt = rand_amount()
                rows.append((f"TX{tid},{ts},{amt},PENDING",
                             {"tx_id": f"TX{tid}", "inst": inst, "wall": wall, "status": "PENDING",
                              "amount": amt, "epoch": off == "epoch"}))
        # deliberate same-instant tie written with different offsets: the LATER row in the file wins
        tie_id = f"TX{rng.choice([x for x in range(100000, 999999) if x not in ids])}"
        tie_inst = rand_instant(base, 48).replace(second=0)
        for off, st in zip(rng.sample(["+05:30", "Z", "-08:00", "+10:00"], 2), ["SUCCESS", "FAILED"]):
            ts, wall = fmt_ts(tie_inst, off); amt = rand_amount()
            rows.append((f"{tie_id},{ts},{amt},{st}",
                         {"tx_id": tie_id, "inst": tie_inst, "wall": wall, "status": st,
                          "amount": amt, "epoch": False}))
        rng.shuffle(rows)
        # malformed rows (must be skipped entirely, even if they share a tx_id with a good row)
        victim = rng.choice(ids)
        bad = [
            "BAD1,2026-03-01T10:00:00Z,abc,SUCCESS", "BAD2,,10.00,SUCCESS",
            ",2026-03-01T10:00:00Z,10.00,SUCCESS", "BAD3,not-a-date,10.00,SUCCESS",
            "BAD4,2026-03-01T10:00:00Z,10.00,REFUNDED", "BAD5,2026-03-01T10:00:00Z",
            f"TX{victim},2027-01-01T00:00:00Z,oops,FAILED",
        ]
        for b_ in bad:
            rows.insert(rng.randint(0, len(rows)), (b_, None))
        good = [(i, r) for i, (_, r) in enumerate(rows) if r is not None]
        exp = survivors(good)
        wrong = [survivors(good, tz_ok=False), survivors(good, epoch_ok=False),
                 survivors(good, rule_c=False)]
        if all(exp != w for w in wrong):         # every sub-rule must matter
            return "tx_id,timestamp,amount,status\n" + "\n".join(l for l, _ in rows) + "\n", exp
    raise RuntimeError("could not build a discriminating dedupe dataset")

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

def write_dataset(name, text):
    path = os.path.join(DATA_DIR, name)
    with open(path, "w", newline="") as f:
        f.write(text)
    return path

# ------------------------------------------------------------------ the checks
results, outputs = {}, []          # outputs: (expected, stdout) pairs for the anti-cheat invariant

# check 1: CLI contract (independent of every other check)
sample, _ = make_status_dataset()
p1 = write_dataset("cli_sample.csv", sample)
rc0, _, err0 = run([])
rc2, _, err2 = run([p1, "extra-arg"])
results["cli"] = (rc0 == 2 and "usage" in err0.lower() and "Traceback" not in err0
                  and rc2 == 2 and "Traceback" not in err2)

# check 2: status rules (two random datasets, both must match)
ok = True
for i in range(2):
    text, exp = make_status_dataset()
    rc, out, _ = run([write_dataset(f"status_{i}.csv", text)])
    outputs.append((exp, out))
    ok = ok and rc == 0 and matches(out, exp)
results["status"] = ok

# check 3: dedupe (instants, epoch, PENDING rule) + malformed rows (two random datasets, both must match)
ok = True
for i in range(2):
    text, exp = make_dedupe_dataset()
    rc, out, _ = run([write_dataset(f"dedupe_{i}.csv", text)])
    outputs.append((exp, out))
    ok = ok and rc == 0 and matches(out, exp)
results["dedupe"] = ok

# anti-cheat: identical stdout for datasets with different answers => script ignores its input
cheat = False
for a in range(len(outputs)):
    for b in range(a + 1, len(outputs)):
        if outputs[a][0] != outputs[b][0] and outputs[a][1].strip() and outputs[a][1] == outputs[b][1]:
            cheat = True

score = 0.0 if cheat else round(sum(WEIGHTS[k] for k, v in results.items() if v), 2)
with open(os.path.join(LOGS, "reward.txt"), "w") as f:
    f.write(f"{score:.2f}\n")
with open(os.path.join(LOGS, "breakdown.json"), "w") as f:
    json.dump({"checks": results, "weights": WEIGHTS, "cheat_detected": cheat, "reward": score}, f, indent=2)
print(json.dumps({"checks": results, "cheat_detected": cheat, "reward": score}))
PYEOF
