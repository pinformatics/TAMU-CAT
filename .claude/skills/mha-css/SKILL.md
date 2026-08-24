---
name: mha-css
description: Edit this repo's main Rails CSS files, especially app/assets/stylesheets/application.css and accessibility.css, while preserving the existing TAMU CAT design system.
---

# MHA CSS

Use this skill when changing the MHA Survey Portal / TAMU CAT visual system, layouts, component classes, responsive behavior, or high-contrast/accessibility CSS.

## Files

- Main stylesheet: `app/assets/stylesheets/application.css`
- High-contrast and accessibility overrides: `app/assets/stylesheets/accessibility.css`
- Generated CSS such as `app/assets/builds/tailwind.css` should stay ignored and uncommitted.

## Read First

Before editing CSS, inspect the view/helper that uses the class and the nearby existing CSS. Prefer `rg` searches for the class, component prefix, and page-specific terms.

Use existing patterns before adding new ones:

- `.c-*` for reusable components.
- `.c-block__element` and `.c-block--variant` for component elements/variants.
- `.u-*` for generic utilities like spacing, flex, actions, and text alignment.
- `.is-*` for state.
- `btn`/`btn-*` classes are usually emitted by Rails helpers; inspect the helper before inventing button styling.

## Design Tokens

Prefer the variables defined in `:root` over literal values:

- Spacing: `--spacing-*`, `--container-gutter*`, `--container-padding-y*`
- Type: `--font-size-*`, `--font-weight-*`, `--line-height-*`
- Radius/shadow: `--border-radius-*`, `--shadow-*`
- Color: `--primary-color`, `--gray-*`, semantic success/warning/error/info variables, and TAMU maroon variables

Use one-off colors only when the existing file already uses them for a specific chart/status family or when a new semantic token would be overkill.

## Editing Rules

- Add new rules near the related component section when practical; avoid reorganizing the large stylesheet during feature work.
- Scope page-specific styles with an existing page/component wrapper instead of broad global selectors.
- Favor existing layout utilities such as `u-stack`, `u-actions`, `u-grid`, `u-responsive-split`, `c-table-wrapper`, `c-card`, and `c-stats-grid`.
- Keep text inside buttons, cards, tables, and compact panels from overflowing on mobile; use `minmax(0, 1fr)`, wrapping, scrolling table wrappers, or stable dimensions where needed.
- Avoid `!important` in `application.css`; reserve it mainly for high-contrast overrides or interoperability fixes that are already constrained.
- Do not introduce large palette shifts, decorative gradients/orbs, or unrelated restyling while fixing a narrow UI issue.
- For motion, provide a `prefers-reduced-motion: reduce` fallback.

## Accessibility

When adding interactive states, include visible `:focus-visible` behavior or reuse an existing class that already has it. Do not rely on color alone for status. If a new color/state must work in high contrast, add the corresponding `body.high-contrast` override in `accessibility.css`.

## Verification

For CSS-only edits, at minimum run `git diff --check`. When classes are used by Rails views, run the focused controller/system test if one exists and view the page locally through Docker:

```powershell
docker compose up -d web css
```

If the change affects generated Tailwind assets or the running app has stale styles, run:

```powershell
docker compose exec web bin/rails tailwindcss:build
```

For risky layout changes, inspect desktop and mobile widths before finishing.
