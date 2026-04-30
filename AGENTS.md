# AGENTS.md

This file is the entry point for any AI agent (Claude Code, Copilot CLI, Codex, Gemini CLI, custom subagents, scheduled remote agents) that operates on this repository.

## You are bound by the Constitution

The repository's authoritative charter is `Constitution.md` at the root. **Read it first.** It overrides default model behavior, plugin defaults, and any tool-specific guidance whenever they conflict, except where the user gives explicit instructions in chat or in `CLAUDE.md`.

The most load-bearing rule is reproduced inline below — you may not skip it:

## Article I — Anti-Bluff Testing (Non-Negotiable)

> **A passing test or Challenge MUST prove that the product really works. A test that passes while the product is broken is a defect more serious than the original bug.**

When writing tests or Challenges as an agent:

1. **Exercise the real artifact.** Run the actual built binary against real inputs. Stub only true external boundaries (kernel, network), never the code under test.
2. **Assert observable outcomes.** Verify files exist on disk with required content, exit codes, subprocess output, systemd unit states. "I called the function" is not an assertion.
3. **Fail loudly when the feature is missing.** Every test must be one whose green status genuinely depends on the production code being correct. Do mutation spot-checks: temporarily break the code and confirm the test goes red. If it doesn't, that test is a bluff and must be rewritten.
4. **No `t.Skip`, no `pending`, no `|| true`, no `--no-fail`, no swallowed exit codes.** A test that cannot run is not a test.
5. **Challenges must reproduce the real failure mode.** A memory-protection Challenge must actually allocate enough memory to trip the threshold. Synthetic shortcuts that bypass the hazard are forbidden.
6. **Every public feature has at least one Challenge.** No feature ships without an end-to-end Challenge a user can reproduce by reading the script.
7. **The suite is part of the definition of done.** A change is not complete until `make test` and `make challenges` pass on a clean checkout.

## How to act

- **Before declaring any task done**, run the relevant tests AND Challenges and report the *actual* outcome (paste output or a verifiable summary). Do not say "done" if you have not run the verification.
- **Before writing tests**, read `Constitution.md` Article I and the existing tests in this repo to match style.
- **Before adding a feature**, write or update the Challenge that proves the feature works end-to-end.
- **When you finish a logical unit of work**, commit cleanly. The `origin` remote is configured to push to all four mirrors (GitHub, GitLab, GitFlic, GitVerse) — `git push origin main` covers all four.
- **Never weaken the Constitution.** Submodule agents inherit it.

## Other articles (summary)

The full text is in `Constitution.md`:

- **Article II — Idempotency and Reversibility.** Mutating scripts must be idempotent and reversible; never restart `systemd-logind`, never touch fstab/swap/GRUB.
- **Article III — Documentation Parity.** Every user-facing tool ships Markdown + HTML + PDF. `make docs` produces all three.
- **Article IV — Observable Behavior Over Code Beauty.** Logs and on-disk artifacts beat internal elegance.
- **Article V — Multi-Upstream Discipline.** Every commit on `main` must reach all four mirrors via `origin`.
- **Article VI — Submodule Constitutions.** Any submodule must include its own `Constitution.md`, `CLAUDE.md`, and `AGENTS.md`.

## Pointers for productive sessions

- The user-facing project context is in `CLAUDE.md` — read it for architecture and command map.
- The post-mortem at `reports/Crash_Report.md` is the load-bearing context behind every design choice.
- The newer Go monitoring daemon lives under `oom-watch/` (see its own README and `Constitution.md` if present).
- Build/lint/test commands are in the top-level `Makefile` (`make help`).
