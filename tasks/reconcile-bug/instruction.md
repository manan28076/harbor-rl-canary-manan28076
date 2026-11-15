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

A CSV file with the header `tx_id,timestamp,amount,status`. These files are
exported from several upstream systems (a payment gateway, a legacy ledger,
finance spreadsheets), so values are **not always formatted uniformly**: the tool
has to cope with real-world exports, not only tidy ones.

| column      | meaning                                                                                      |
|-------------|----------------------------------------------------------------------------------------------|
| `tx_id`     | transaction identifier (string)                                                              |
| `timestamp` | when the record was written; different systems, different timezones. A timestamp that carries no timezone information is UTC |
| `amount`    | a monetary amount, written the way finance exports usually write money                       |
| `status`    | `SUCCESS`, `FAILED` or `PENDING` (case-insensitive, surrounding spaces ignored)              |

## Rules

1. **Malformed rows are skipped entirely.** A row is malformed if a field is missing
   or empty, the `amount` is not a number, the `timestamp` cannot be understood, or
   the `status` is not one of the three above. A skipped row has no effect on any
   other row.
2. **Same transaction.** `tx_id` values are compared case-insensitively and
   ignoring surrounding spaces: `tx100`, `TX100` and ` Tx100 ` are one transaction.
3. **Duplicate transactions.** A transaction may appear several times (for example a
   `PENDING` row later followed by a `SUCCESS` row, or a `PENDING` retry logged after a
   final row). Only **one** record per transaction is used, chosen like this:
   * `SUCCESS` and `FAILED` are *final*; `PENDING` is provisional. A final record always
     beats a `PENDING` record, even when the `PENDING` record has a later timestamp.
   * Among records of the same kind, the one with the **latest timestamp, compared as an
     absolute point in time**, wins.
   * If two records have exactly the same instant (and the same kind), the one that
     appears later in the file wins.

   Every rule below applies to that single surviving record.
4. A surviving `SUCCESS` record is *valid*, a surviving `FAILED` record is
   *failed*, and a surviving `PENDING` record is neither (it is ignored).
5. **Rounding.** Each amount is rounded half-up to 2 decimal places individually,
   *before* it is added to the total.

## Output

```json
{"total_valid_amount": 1234.5, "valid_count": 3, "failed_count": 1}
```

* `total_valid_amount` — sum of the (rounded) `amount` over valid records, a JSON
  number with at most 2 decimal places.
* `valid_count`, `failed_count` — JSON integers.
* No other keys.
