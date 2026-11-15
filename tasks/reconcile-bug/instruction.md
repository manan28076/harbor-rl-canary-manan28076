# Fix the transaction reconciler

`/app/reconcile.py` is a small command-line tool that reconciles a CSV of payment
transactions into a JSON summary. It currently produces wrong results. Make it
behave exactly as specified below. Edit the file in place; keep it a single
Python 3 script at `/app/reconcile.py` that uses only the standard library.

## Command line

```
python3 /app/reconcile.py <transactions.csv>
```

* Exactly one argument (the CSV path) is required. With any other number of
  arguments the tool prints a line starting with `usage:` to **stderr** and exits
  with status **2** (no traceback).
* On success it prints **one JSON object** to **stdout** and exits 0.

## Input

A CSV file with the header `tx_id,timestamp,amount,status`.

| column      | meaning                                                                                   |
|-------------|-------------------------------------------------------------------------------------------|
| `tx_id`     | transaction identifier (string)                                                           |
| `timestamp` | ISO-8601 date-time, e.g. `2026-03-01T10:00:00Z`, `2026-03-01T15:30:00+05:30`, or `2026-03-01T10:00:00`; **or** Unix epoch seconds as digits only, e.g. `1772359200` |
| `amount`    | decimal number such as `1234.50`                                                          |
| `status`    | `SUCCESS`, `FAILED` or `PENDING` (case-insensitive, surrounding spaces ignored)           |

A timestamp without a UTC offset is to be read as UTC. Epoch seconds are UTC.

## Rules

1. **Malformed rows are skipped entirely.** A row is malformed if it has a missing
   or empty field, a `tx_id` that is empty, an `amount` that is not a finite
   number, a `timestamp` that cannot be parsed, or a `status` that is not one of
   the three above. A skipped row has no effect on any other row.
2. **Duplicate `tx_id`s.** A transaction may appear several times (for example a
   `PENDING` row later followed by a `SUCCESS` row, or a `PENDING` retry logged after a
   final row). Only **one** record per `tx_id` is used, chosen like this:
   * `SUCCESS` and `FAILED` are *final*; `PENDING` is provisional. A final record always
     beats a `PENDING` record, even when the `PENDING` record has a later timestamp.
   * Among records of the same kind, the one with the **latest timestamp, compared as an
     absolute point in time**, wins.
   * If two records have exactly the same instant (and the same kind), the one that
     appears later in the file wins.

   Every rule below applies to that single surviving record.
3. A surviving `SUCCESS` record is *valid*, a surviving `FAILED` record is
   *failed*, and a surviving `PENDING` record is neither (it is ignored).

## Output

```json
{"total_valid_amount": 1234.5, "valid_count": 3, "failed_count": 1}
```

* `total_valid_amount` — sum of `amount` over valid records, a JSON number
  rounded to 2 decimal places (half up).
* `valid_count`, `failed_count` — JSON integers.
* No other keys.
