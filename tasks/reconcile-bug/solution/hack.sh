#!/bin/bash
# RED-TEAM script (NOT a real solution). Replaces reconcile.py with a stub that
#   * passes the CLI check honestly (usage + exit 2), but
#   * IGNORES the input CSV and prints hardcoded JSON.
# Against a naive verifier that runs one fixed CSV with one fixed expected answer,
# this scores high. The hardened tests/test.sh must score it 0.00.
cat > /app/reconcile.py <<'PYEOF'
import sys
if len(sys.argv) != 2:
    print("usage: reconcile.py <transactions.csv>", file=sys.stderr)
    sys.exit(2)
print('{"total_valid_amount": 1234.5, "valid_count": 3, "failed_count": 1}')
PYEOF
echo "Done!"
