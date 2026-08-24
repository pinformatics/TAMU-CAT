---
name: mha-survey-portal
description: Work on this repo's MHA Survey Portal/TAMU CAT Rails app, especially grade imports, reports, Docker, OAuth, Heroku, and release handoff tasks.
---

# MHA Survey Portal

Use this skill when working in the MHA Survey Portal / TAMU Competency Assessment Tool repo.

Start with [docs/AGENT_BRIEF.md](../../../docs/AGENT_BRIEF.md). It is the shared concise brief for Gary/Claude and Codex.

Important constraints:

- Use Docker by default unless local Ruby is explicitly available.
- Do not print secrets from `.env`, OAuth credentials, Heroku API keys, Rails master keys, or production database URLs.
- Keep release changes narrow and easy to review before the September 7, 2026 dev push.
- Preserve grade-import dry-run review, duplicate suppression, pending student reconciliation, and course-rating semester scoping.
- Keep imported course-derived ratings distinct from self/advisor ratings in reports and competency views.

Task routing:

- Grade imports: read `docs/GRADE_IMPORTS.md` and `docs/FAILED_IMPORT_TROUBLESHOOTING.md`.
- Reports: inspect `app/services/reports/`, `app/controllers/reports_controller.rb`, `app/views/reports/`, and related tests.
- Architecture/handoff: read `docs/ARCHITECTURE_MAP.md` and only the relevant sections of `docs/TECHNICAL_HANDOFF.md`.

Verification:

- Run focused tests for touched behavior.
- Run RuboCop on touched Ruby files.
- Summaries should say what changed, what was verified, and what still needs Heroku/dev-app validation.
