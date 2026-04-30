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

## Definition of done for any change

- `go vet ./...` clean
- `go test -count=1 ./...` green
- `bash ../challenges/run-all.sh` green
- The mutation audit Challenge has been run at least once on the changed code (i.e., temporarily break a representative production line for the change, confirm the relevant test goes red).
- If the change adds a feature, at least one new Challenge covers it end-to-end.
