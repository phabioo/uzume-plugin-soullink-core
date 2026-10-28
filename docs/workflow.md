# Working with Claude Code

Adapted from the Uzume workflow (https://github.com/phabioo/uzume, `docs/workflow.md`).

## Hybrid mode

- Development happens in Claude Code cloud sessions.
- Real games are tested only locally by Fabio, using the Uzume developer mode (live values, events, log). Recorded game data stays local.

## What can be verified in the cloud

Verifiable:
- Lua code with lua5.4 against synthetic data generated from documented formats (and the Uzume test core once the API exists).
- Manifest and i18n checks, docs link checks, CI.

Not verifiable (only locally by Fabio):
- Behavior with real games: memory map coverage, offsets, encounters, languages.
- UI look and feel inside the app, controller operation, performance.
- Real ROMs/BIOS/game dumps must not enter the repository or the cloud.

## Roles

**Opus is exclusively the orchestrator** and writes no product code. It bundles tasks into sensible packages, delegates via brief (template below) to the Sonnet 5.5 agents in `.claude/agents/`, reviews the result and either accepts it or sends it back to the same agent with concrete corrections.

Flow: break the task into 2-3 packages; write the brief; the subagent implements and reports, it does not commit; Opus reviews via `git diff --stat`, a targeted diff and the test result; accept or correct via `SendMessage` to the same agent; commit/PR by Opus.

| Agent | Model | Responsibility |
|---|---|---|
| `plugin-implementer` | Sonnet 5.5 (`sonnet`) | Plugin code (Lua), UI building blocks, i18n, tests |
| `game-adapter-implementer` | Sonnet 5.5 (`sonnet`) | Per-game adapters, data decoding, asset extraction, `docs/games/` |
| `ci-implementer` | Sonnet 5.5 (`sonnet`) | GitHub Actions, packaging, signing workflow (later) |
| `docs-writer` | Sonnet 5.5 (`sonnet`) | `docs/`, README |
| `scout` | Haiku 5.5 (`haiku`) | read-only: search, read logs/CI output, summarize |

Agents use the model aliases so they follow new releases. Haiku is for search, extraction and summaries, not for code that needs judgment.

## Brief template

```text
Goal: <one sentence>
Context: <doc or Uzume architecture section; optionally a short quote>
Files/paths: create/modify: <...>; touch nothing else
Acceptance criteria:
- <...>
Check command: <command, output trimmed>
Report: changed files; commands + result, one line each; open points.
Do not return full logs or file contents. Do not commit.
```

## Token-saving rules

- Do not split tasks too finely: prefer 2-3 sensible packages over many mini-assignments, since every agent starts cold.
- Agents do not explore freely; they get paths and the spec location.
- Read only the relevant file or section, never everything.
- Opus reviews via `git diff --stat`, a targeted diff and the test result, not by re-reading whole files.
- Always filter/trim command output (`| tail -n 30`, errors only). Long logs are read and summarized by `scout`.
- For corrections, continue the agent via `SendMessage` instead of starting a new one; the context is preserved.
- One work package per thread; new threads instead of long histories.

## Packages and PRs

- One PR per package with green CI, one topic per PR.
- Every PR description has a `## Changelog` section (template in `.github/pull_request_template.md`, `none` for CI/docs/test-only PRs); CI checks it and the release notes are built from it.
- Milestone PRs update the status line in `docs/roadmap.md` and `README.md` (status = version line; open work = issues, not the roadmap); READMEs stay short, detail goes to `docs/`.
- Auto-merge is enabled on all PRs once the repository has "Allow auto-merge" and required checks configured.

## Issues and milestones

- Open work is tracked as GitHub issues in milestones, here and in phabioo/uzume. Milestones are Uzume releases with the same title in every repository: "Uzume 21" (first stable of the new numbering; local tests needed for it) and "Uzume 22" (next line).
- A plugin issue sits in the milestone of the Uzume release it is needed for or tested with; plugin improvements without such a tie have no milestone. Plugins keep their own SemVer versions; only Uzume changes its numbering.
- Every issue in "Uzume 21" or "Uzume 22" gets exactly one label `priority:high`, `priority:medium` or `priority:low` (order within the milestone). Deliberately deferred issues move to the milestone "Later" with a comment why.
- Labels: `work-package` (one thread, one PR), `leftover`, `local-test` (needs Fabio's real game or hardware), `triage`, plus theme labels (emulation, randomizer, plugins, together, platforms, app, install-and-sharing).
- One thread works one issue; the PR body says "Closes #N"; findings become issues.
- User documentation of the plugins lives in the central Uzume wiki page [Plugins](https://github.com/phabioo/uzume/wiki/Plugins); this repository has no own wiki. Developer docs stay here.
- Decision record: Uzume ADR 0036 (`docs/adr/0036-issues-milestones-wiki-and-numbering.md`).

## Rules

- The repository language is English.
- No ROMs, BIOS, firmware, game files, extracted assets or RAM dumps of real games in the repository or in tests; only synthetic data.
