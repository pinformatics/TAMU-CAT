---
name: mha-survey-portal
description: Work on this repo's MHA Survey Portal/TAMU CAT Rails app, especially grade imports, reports, Docker, OAuth, Heroku, and release handoff tasks.
metadata:
  short-description: MHA Survey Portal repo guidance
---

# MHA Survey Portal

Use this skill when working in the MHA Survey Portal / TAMU Competency Assessment Tool repo.

## First Read

Read [docs/AGENT_BRIEF.md](../../../docs/AGENT_BRIEF.md) before making task decisions. It contains the current release priorities, Docker workflow, import/report context, testing guidance, and handoff norms.

Then read only the deeper docs that match the task:

- Grade imports: `docs/GRADE_IMPORTS.md`
- Failed imports: `docs/FAILED_IMPORT_TROUBLESHOOTING.md`
- Architecture: `docs/ARCHITECTURE_MAP.md`
- Full operational handoff: `docs/TECHNICAL_HANDOFF.md`
- Known risks / next work: `docs/KNOWN_ISSUES.md`, `docs/NEXT_STEPS.md`

## Operating Rules

- Use Docker by default; the host may not have Ruby installed.
- Keep changes small and testable before the September 7, 2026 dev push.
- Do not print secrets from `.env`, OAuth credentials, Heroku API keys, Rails master keys, or production database URLs.
- Preserve user changes in the working tree.
- Keep docs concise and link to deeper docs instead of duplicating long explanations.

## Domain Guardrails

Grade imports:

- Preserve dry-run review, commit/rollback, duplicate suppression, pending unmatched rows, and semester scoping.
- Remember uploads are stored as `GradeImportFile#source_file` and jobs receive `grade_import_file_ids`.
- Heroku import reliability may still require bigger dynos or durable shared Active Storage if using a separate worker.

Reports:

- Keep self, advisor, and imported course-derived ratings distinct.
- Verify filters and exports when report aggregation changes.

## Verification

Run focused tests for touched behavior and RuboCop for touched Ruby files. Broaden testing when changing shared models, imports, reports, auth, jobs, or migrations.
