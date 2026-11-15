# Harbor RL Submission — Manan (@manan28076)

## 1. Loom Walkthrough Video
- **Video URL:** [Watch 5-Minute Walkthrough](TODO_PASTE_LOOM_LINK)
  *(link sharing set to "Anyone with the link can view")*

## 2. Task & Calibration Summary
Task: `tasks/reconcile-bug` — fix `/app/reconcile.py`, a CSV payment-transaction reconciler (`tx_id,timestamp,amount,status` -> JSON `total_valid_amount / valid_count / failed_count`). The script is 72 lines.

- **Bug 1 (Easy):** the argument-count check is `len(sys.argv) < 1`, which can never be true, so running with no argument (or extra arguments) crashes with an `IndexError` traceback / silently accepts extras instead of printing `usage:` and exiting 2.
- **Bug 2 (Medium):** status filtering uses `else:` after the `FAILED` branch, so `PENDING` rows are counted as valid (inflating `valid_count` and `total_valid_amount`) instead of being ignored.
- **Bug 3 (Hard):** a bundle of five messy-input / duplicate-resolution rules that are all stated in `instruction.md` but only show up on tricky inputs: (1) timestamps must be compared as absolute instants (UTC offsets, naive = UTC, and Unix-epoch seconds, which are silently skipped as "malformed" by the buggy parser); (2) a later `PENDING` row must never replace a final `SUCCESS`/`FAILED` row; (3) the CSV may start with a UTF-8 BOM, which breaks the header and makes every row get skipped; (4) amounts like `"$1,234.50"` and >2 decimals, each rounded half-up to cents before summing; (5) `tx_id` matching is case-insensitive and ignores spaces.
- **Calibration Scores:** `nop` = `0.00` | `oracle` (`solve.sh`) = `1.00` | Partial `oracle` (Bug 1+2 fixed, whole Bug 3 broken) = `0.50`; with only ONE Bug 3 sub-rule re-broken (the `rank` line, shown in video) = `0.90` | `hack.sh` = `0.00`

## 3. Ablation & RL Advantage Table (`terminus-2`, `k=3` Trials)

Binary reward of a trial = 1 if the dense score is 1.00 (all three checks pass), else 0. Advantage = trial reward − mean reward of the 3 trials. Numbers generated with `helpers/compute_advantage.py`.

| Run | Change Tested | Trial 1 (Binary / Dense) | Trial 2 (Binary / Dense) | Trial 3 (Binary / Dense) | Mean Binary | Mean Dense ($\bar{R}$) | Binary Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) | Dense Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Run 1: Baseline** | Original 3-bug task | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |
| **Run 2: Ablation** | `TODO: the ONE change (e.g. sample CSV placed in /app)` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |

## 4. Trajectory Forensics (`trajectory.json`)
- **Where the Agent Failed in Run 1:** `TODO: name the exact step / bash command in the failed trial's trajectory.json where it made the mistake or stopped without testing the cross-timezone duplicate case (2-3 sentences).`
- **Ablation Hypothesis & Result:** `TODO: what you changed, why you expected it to help given the failure above, and how the agent's commands in Run 2 changed (2-3 sentences).`

## 5. Dense Reward & Anti-Cheat Design
- **My Dense Reward Weights (`tests/test.sh`):** `reward = 0.20·CLI + 0.30·status + 0.10·(time + rank + bom + money + idcase)`. Bug 1 and Bug 2 are worth 0.50 together; Bug 3 is worth the other 0.50 but is split into five independent 0.10 sub-checks, each tested on its own isolated random datasets (e.g. the BOM dataset has only plain rows, the rank dataset only `Z` timestamps), so fixing one rule can never pass or fail another's check. The split gives a gradient (a trial that fixes 4 of 5 Bug 3 rules scores 0.90, not 0.50), so partial progress on the hard bug is rewarded instead of all-or-nothing.
- **How `solution/hack.sh` Cheated & How I Blocked It:** `hack.sh` replaces `reconcile.py` with a stub that implements the arg check honestly but ignores the CSV and prints hardcoded JSON — enough for a naive verifier that checks one fixed CSV against one fixed answer. The hardened `test.sh` (a) generates fresh random datasets at verify time (random IDs, amounts, statuses, offsets, so there is nothing to hardcode), (b) computes expected values from the generator's own data, never from `/app`, (c) requires two independent random datasets per check to both match (every dataset is built so that the specific wrong behaviour it targets changes the answer), and (d) has an invariant: if two datasets with different correct answers produce the same non-trivial stdout, the script is ignoring its input and the total reward is forced to `0.00` (all-zero output is not flagged, so an honest-but-broken script keeps its partial credit). It fails closed (`reward.txt` starts at 0.00). Every dedupe dataset is also checked to be discriminating (the "ignore the timezone" answer must differ from the correct one).
- **Remaining Reward-Hacking Risk:** `The verifier runs in the same container, as the same user and with the same Python interpreter as the agent, so a smarter agent can tamper with the environment outside /app: drop a sitecustomize.py / patch the stdlib so the verifier's own python reports success, or make reconcile.py spawn a background process that overwrites /logs/verifier/reward.txt after the verifier finishes. Fix: run the verifier with a pinned interpreter (python -I -S) from outside the agent's writable area, execute the agent's script in a sandbox as an unprivileged user with /logs and /tests unreadable/unwritable, and write the reward from a separate final process after killing all children.`

## 6. AI Tool Workflow
- **AI Tool & Model Used:** `TODO e.g. Claude Code (claude-sonnet-...) — transcripts in ai_transcripts/`
- **How I Avoided Prompt Leakage:** `TODO (suggested, edit to match what you really did): the buggy environment/ and solution/ were written in one AI session, while instruction.md was written in a separate session/by me from the business rules only, so it states the CSV format, output schema and rules but never names the functions or lines that contain bugs; I re-read it against the diff of buggy vs fixed code to confirm no spoilers.`
