# oom-watch — Submodule Constitution

This submodule is governed by the **project-root `Constitution.md`** at `../Constitution.md`. Read that first.

Per Article VI of the project Constitution, this file MUST exist for this submodule and MUST NOT weaken Articles I–V.

## Re-statement of Article I (binding)

> **A passing test or Challenge MUST prove that the product really works. A test that passes while the product is broken is a defect more serious than the original bug.**

For oom-watch specifically:

1. Every Go test must use real fixtures or temporary directories with real /proc-shaped data. No method-stubs masquerading as tests.
2. Every shell Challenge in `../challenges/` must invoke the **built `oomwatch` binary** (not source-level Go test runners) and must assert against artifacts on disk produced by that binary.
3. Filesystem assertions must be specific: file path, byte count > N, content `grep -q`. Asserting only "exit 0" is a bluff.
4. Every public flag (`-dry-run`, `-one-shot`, `-config`, `-print-config`, `-version`) is exercised by at least one Challenge.
5. The mutation Challenge (`challenge-tests-are-not-bluffs.sh`) is mandatory and runs in CI.

## Submodule-specific rules

1. **Zero external Go dependencies.** stdlib only. This keeps the binary statically buildable and reproducible without network access.
2. **atop is the only data source.** Do not silently fall back to /proc parsers if atop is missing — fail loudly with `ErrAtopMissing`.
3. **Atomic on-disk writes.** Reports must be written to a temp file in the same directory and renamed; partial files must never be observable.
4. **Forensic completeness over uptime.** A report with 8 of 10 sections + a `Capture errors` section is acceptable; a report with no errors but missing data is not.
5. **No silent rate limiting.** When the cooldown suppresses a report, log it. Operators reviewing logs must be able to reconstruct what was *not* reported and why.
6. **Forensic enrichment captured at snapshot time, not report-read time.** `/proc/<pid>/cmdline` and `/proc/<pid>/status` only exist while the process is running. Capturing them lazily would mean losing the evidence the daemon exists to preserve.
7. **Pre-flight validation before activation.** The deployer (`scripts/install-and-verify.sh`) MUST run `oomwatch -dry-run` against the installed config BEFORE asking systemd to start the unit. Cryptic `code=exited, status=2` messages must be replaced by precise validator errors with remediation.
8. **Auto-remediation preserves user customisation.** When an installed config fails validation, the deployer backs it up to `config.json.broken.<ts>` BEFORE replacing it. Silent overwrite of operator customisation is forbidden.
9. **Sandbox trade-offs are documented.** The systemd unit deliberately does NOT enable `RestrictNamespaces`, `SystemCallFilter`, `CapabilityBoundingSet`, or `SystemCallArchitectures` because they SIGKILL atop with empty stderr (`atop exit -1: `). Inline comments in the unit file name the failure symptom so a future contributor cannot silently re-enable them without testing.
10. **Cross-UID build resilience.** Every `go build` invocation passes `-buildvcs=false`. The repo may live on a mount owned by a different UID than the builder; without this flag, git's "dubious ownership" causes builds to fail with `error obtaining VCS status`. We do not consume the VCS stamp.

## Verified deployment target

This submodule's correctness is field-tested on **ALT Linux 11 "Salvia"** (Sisyphus branch), kernel 6.12.61-6.12-alt1, systemd 258, atop 2.12.1, x86_64. Changes to the deployer, unit file, or build flags MUST continue to work on this baseline; runbook and architecture docs name each ALT-specific accommodation. Other distros are expected to work; only this one has been verified end-to-end including the real-pressure Challenge.

## Definition of done for any change

- `go vet ./...` clean.
- `go test -count=1 ./...` green.
- `bash ../challenges/run-all.sh` green — **7 / 7 PASS**.
- The mutation audit Challenge (`challenge-tests-are-not-bluffs.sh`) runs as part of `run-all.sh`; if you added new production code, also do a manual mutation test on a representative line to confirm a new test catches it.
- If the change adds a feature, at least one new Challenge covers it end-to-end with **specific** assertions (file paths, content substrings, exit codes — never just `exit 0`).
- Documentation updated for parity (Article III): the manual, deployment guide, runbook, or architecture doc — whichever is closest in scope to the change. HTML/PDF re-rendered via `bash ../build-docs.sh`.
