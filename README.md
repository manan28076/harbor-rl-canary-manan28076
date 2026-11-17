# Harbor RL Submission — Manan (@manan28076)

> A Harbor RL environment where an agent must fix a broken CSV payment reconciler, with a **dense, randomized, hack-resistant verifier**, a measured baseline/ablation with `terminus-2`, and trajectory forensics.

**Results at a glance**

| | |
| :--- | :--- |
| Task | `tasks/reconcile-bug` — fix `/app/reconcile.py` (76 lines, 3 planted bugs) |
| Agent / model | `terminus-2` + `gemini/gemini-flash-lite-latest`, `k=3`, `-n 1` |
| Run 1 (baseline) | dense `0.80, 0.90, 0.80` (mean 0.83) — binary reward is all `0` |
| Run 2 (ablation) | dense `1.00, 1.00, 1.00` — one change: a sample production CSV in `/app` |
| Validation | `nop` = 0.00, `oracle` = 1.00, `hack.sh` = 0.00 (all run in real Harbor) |

---

## 1. Loom Walkthrough Video
- **Video URL:** [Watch 5-Minute Walkthrough](https://www.loom.com/share/fc10a41f732341cab4630527daf1b534)
  *(link sharing set to "Anyone with the link can view")*

---

## 2. Task & Calibration Summary
**Task:** `tasks/reconcile-bug` — fix `/app/reconcile.py`, a CSV payment-transaction reconciler. It reads `tx_id,timestamp,amount,status` and prints one JSON object: `{"total_valid_amount": ..., "valid_count": ..., "failed_count": ...}`. The buggy script is 76 lines.

### Planted bugs

| # | Difficulty | What is wrong |
| :-- | :-- | :-- |
| 1 | Easy | The argument check is `len(sys.argv) < 1`, which can never be true. With no argument the script crashes with an `IndexError` instead of printing `usage:` and exiting 2, and extra arguments are silently accepted. |
| 2 | Medium | Status handling uses `else:` after the `FAILED` branch, so `PENDING` rows are counted as valid (inflating `valid_count` and `total_valid_amount`) instead of being ignored. |
| 3 | Hard | A bundle of **six** messy-input / duplicate-resolution rules (below). |

**Bug 3 — six independent sub-rules**

| Sub-rule | Behaviour the agent must implement | Stated in `instruction.md`? |
| :-- | :-- | :-- |
| `time` | Duplicate `tx_id`s are resolved by absolute instant (mixed UTC offsets; no offset = UTC; equal instants: later row wins). | Yes |
| `rank` | A later `PENDING` row must never replace a final `SUCCESS`/`FAILED` row. | Yes |
| `idcase` | `tx_id` matching is case-insensitive and ignores surrounding spaces. | Yes |
| `epoch` | Timestamps may be Unix epoch seconds (the buggy parser silently skips them as "malformed"). | Only hinted ("not always formatted uniformly") |
| `bom` | The file may start with a UTF-8 BOM (the buggy reader sees a broken header, so every row is skipped). | Only hinted |
| `money` | Amounts like `"$1,234.50"`, with more than 2 decimals, each rounded half-up to cents before summing. | Rounding stated; `$`/commas only hinted |

The business rules are written out; the data-format quirks of real exports are only hinted at, so an agent finds them only by testing on realistic data.

### Calibration scores

| Scenario | Reward | How it was checked |
| :-- | :-- | :-- |
| `nop` (agent does nothing) | `0.00` | Real Harbor |
| `oracle` (`solve.sh`, all bugs fixed) | `1.00` | Real Harbor |
| `oracle` with one Bug 3 sub-rule re-broken (the `rank` line, shown in the video) | `0.90` | Real Harbor |
| `oracle` with all of Bug 3 re-broken (Bugs 1+2 fixed) | `0.40` | Local Docker-free simulation of the verifier (not run in Harbor) |
| `hack.sh` (hardcoded output) | `0.00` | Real Harbor |

### Repository layout
```
harbor-rl-canary-manan28076/
├── README.md
├── tasks/reconcile-bug/
│   ├── task.toml
│   ├── instruction.md              # what the agent sees
│   ├── environment/
│   │   ├── Dockerfile
│   │   ├── reconcile.py            # the buggy script
│   │   └── sample_transactions.csv # Run 2 ablation only
│   ├── solution/
│   │   ├── solve.sh                # reference fix (oracle)
│   │   └── hack.sh                 # red-team reward-hacking script
│   └── tests/test.sh               # dense, randomized, hardened verifier
├── jobs_summary/                   # result.json + trajectory.json for Run 1 and Run 2
└── ai_transcripts/                 # Gemini CLI session
```

### Reproduce
```bash
harbor run -p ./tasks/reconcile-bug -a nop
harbor run -p ./tasks/reconcile-bug -a oracle
harbor run -p ./tasks/reconcile-bug -a terminus-2 --model gemini/gemini-flash-lite-latest -k 3 -n 1
```
Run 1 is the task at commit `38465d4` (`v4: format quirks only hinted`); Run 2 adds the sample file at commit `a69173f` (`ablation A: sample input in /app`).

---

## 3. Ablation & RL Advantage Table (`terminus-2`, `k=3` Trials)

Binary reward of a trial = 1 if the dense score is 1.00 (every check passes), else 0. Advantage = trial reward − mean reward of the 3 trials. All values are computed from the trial rewards recorded in `jobs_summary/`.

| Run | Change Tested | Trial 1 (Binary / Dense) | Trial 2 (Binary / Dense) | Trial 3 (Binary / Dense) | Mean Binary | Mean Dense ($\bar{R}$) | Binary Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) | Dense Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Run 1: Baseline** | Original 3-bug task | `0 / 0.80` | `0 / 0.90` | `0 / 0.80` | `0.00` | `0.83` | `+0.00, +0.00, +0.00` | `-0.03, +0.07, -0.03` |
| **Run 2: Ablation** | Sample production CSV placed in `/app` (BOM, epoch row, `$1,050.005`, mixed-case ids) + one instruction line telling the agent to test on it | `1 / 1.00` | `1 / 1.00` | `1 / 1.00` | `1.00` | `1.00` | `+0.00, +0.00, +0.00` | `+0.00, +0.00, +0.00` |

**Which checks failed in Run 1**

| Trial | Dense reward | Failed checks |
| :-- | :-- | :-- |
| `reconcile-bug__FCyd5kv` | 0.80 | `epoch`, `bom` |
| `reconcile-bug__b6FPAf7` | 0.90 | `epoch` |
| `reconcile-bug__xTacK4N` | 0.80 | `epoch`, `bom` |

**Reading the table.** With a binary reward every Run 1 trial scores 0, the mean is 0 and every advantage is 0, so there is no learning signal. The dense reward separates the trials (`-0.03, +0.07, -0.03`) and rewards the trial that handled more of the hidden rules. In Run 2 all trials hit 1.00, so *both* advantages are 0: the ablation made the task too easy and removed the signal in the opposite direction (the zero-signal trap).

---

## 4. Trajectory Forensics (`trajectory.json`)
- **Where the Agent Failed in Run 1:** In trial `reconcile-bug__FCyd5kv` (0.80) the agent read `reconcile.py` (step 2), rewrote the whole file from the spec with a script `update.py` (step 5), and then only tested it with CSVs it invented itself (`test_all.py` in step 6, `test_edge.py` in step 8). It never looked at realistic export data: none of its 9 commands mentions epoch timestamps, a BOM, `utf-8-sig` or `fromtimestamp`. In step 9 it deleted its test files with `rm -f` and stopped. All 3 trials failed the `epoch` check, and trials `FCyd5kv` and `xTacK4N` also failed the `bom` check; only `b6FPAf7` (0.90) happened to add `utf-8-sig`, but it also never handled epoch timestamps.
- **Ablation Hypothesis & Result:** *Hypothesis:* the agent fails because it only tests on tidy data it makes up itself, so if it can see one realistic production export it will notice the quirks. *Single change:* `/app/sample_transactions.csv` (UTF-8 BOM, an epoch-seconds row, a quoted `"$1,050.005"` amount, mixed-case ids, a late `PENDING` retry) was added to the image, plus one instruction sentence telling the agent to run its fix on it. *Result:* all 3 trials scored 1.00. In trial `He3eqPz` the agent used the sample right away (steps 23–26: it loaded the sample with the old code, rewrote `reconcile.py` with epoch and BOM handling, and ran it on the sample), and its commands now contain `sample` 11 times, `epoch` 10 times and `fromtimestamp`/`utf-8-sig` (versus 0 in Run 1). It ran 30 commands instead of 9.

---

## 5. Dense Reward & Anti-Cheat Design
- **My Dense Reward Weights (`tests/test.sh`):**

  | Check | Weight | What it tests |
  | :-- | :-- | :-- |
  | `cli` | 0.15 | Wrong argument count → `usage:` on stderr, exit code 2, no traceback |
  | `status` | 0.25 | `SUCCESS` / `FAILED` / `PENDING` handling |
  | `time` | 0.10 | Duplicates resolved by absolute instant (offsets, naive = UTC, ties) |
  | `epoch` | 0.10 | Unix epoch timestamps |
  | `rank` | 0.10 | A later `PENDING` never replaces a final row |
  | `bom` | 0.10 | UTF-8 BOM header + CRLF line endings |
  | `money` | 0.10 | `$`/comma amounts, >2 decimals, per-row half-up rounding |
  | `idcase` | 0.10 | Case-insensitive, space-trimmed `tx_id` |

  Bugs 1 and 2 are worth 0.40 together; Bug 3 is worth 0.60 but is split into six independent checks, each tested on its own isolated random datasets (for example the BOM dataset contains only plain rows and the rank dataset only `Z` timestamps), so fixing one rule can never pass or fail another's check. The split gives a gradient: a trial that fixes 5 of 6 Bug 3 rules scores 0.90 rather than 0.40, so partial progress on the hard bug is rewarded instead of all-or-nothing, and the hard bug is worth more than the easy ones combined.
- **How `solution/hack.sh` Cheated & How I Blocked It:** `hack.sh` replaces `reconcile.py` with a stub that implements the argument check honestly but ignores the CSV and prints hardcoded JSON — enough to fool a naive verifier that checks one fixed CSV against one fixed answer. The hardened `test.sh`:
  1. generates **fresh random datasets at verify time** (random ids, amounts, statuses, offsets), so there is nothing to hardcode;
  2. computes the **expected values from the generator's own data**, never from `/app`;
  3. requires **two independent random datasets per check** to both match, and builds each dataset so that the specific wrong behaviour it targets changes the answer;
  4. has an **invariant**: if two datasets with different correct answers produce the same non-trivial stdout, the script is ignoring its input and the total reward is forced to `0.00` (all-zero output is not flagged, so an honest-but-broken script keeps its partial credit);
  5. **fails closed**: `reward.txt` starts at `0.00`, so a verifier crash cannot award credit.
- **Remaining Reward-Hacking Risk:** The verifier runs in the same container, as the same user and with the same Python interpreter as the agent, so a smarter agent could tamper with the environment outside `/app`: drop a `sitecustomize.py` or patch the standard library so the verifier's own Python reports success, or make `reconcile.py` spawn a background process that overwrites `/logs/verifier/reward.txt` after the verifier finishes. *Fix:* run the verifier with a pinned interpreter (`python -I -S`) from outside the agent's writable area, execute the agent's script in a sandbox as an unprivileged user with `/logs` and `/tests` unreadable and unwritable, and write the reward from a separate final process after killing all children.

---

## 6. AI Tool Workflow
- **AI Tool & Model Used:**
  - **Gemini CLI** (`gemini-flash-lite-latest`) — used as an AI coding agent for the packaging step: it copied the `result.json` / `trajectory.json` files from `jobs/` into `jobs_summary/`, ran the pre-push safety check and `git status`. Its session is in `ai_transcripts/`.
  - **Agent under test:** `terminus-2` with `gemini/gemini-flash-lite-latest` for both runs.
  - **Me:** I ran Harbor myself (`nop`, `oracle`, the partial-credit run, `hack.sh`, baseline and ablation), read the trajectories for section 4, recorded the Loom, and did the git commits and the push.
  - The Claude chat is long and contained my API keys, so I did not commit it; I can share a redacted copy on request.
- **How I Avoided Prompt Leakage:** The buggy code, solution, verifier and `instruction.md` were all produced in the same Claude chat, so I could not use a separate session. To limit leakage, `instruction.md` states only the CLI contract, the CSV columns, the output schema and the business rules; it names no function, line or file section that contains a bug, and the data-format quirks (epoch timestamps, BOM, `"$1,234.50"` amounts) are only hinted at ("not always formatted uniformly"). The baseline result supports this: the agent did not find the quirks until the ablation gave it real data.
