# Where things are

A one-page map of Maugham's docs. Each line says what a file is for and when to open it.

## The product

- [`README.md`](../README.md) — what Maugham is and what ships today.
- [`docs/constitution.md`](constitution.md) — the musts and must-nots, each marked *identity* or *position*. Test new work against it.
- [`docs/product.md`](product.md) — an honest overview of what is built.
- [`docs/problem-map.md`](problem-map.md) — the writer's jobs and what serves each one.
- [`docs/roadmap.md`](roadmap.md) — shipped scope and open work. Read the section for the area you're touching, not the whole file.

## Decisions and rules

- [`docs/adr/README.md`](adr/README.md) and the [ADR folder](adr/) — every architectural decision since the master spec. ADRs supersede the master spec; re-read the master spec (`docs/superpowers/specs/2026-05-07-maugham-master-design.md`) only for original-intent questions.
- [docs/tripwires.md](tripwires.md) — "do not do X, here's why it broke before", with the test that enforces each rule.
- [`register/START-HERE.md`](../register/START-HERE.md) — the behavioural claims (verified facts pinned by tests) and Denver's rulings (what should be true).

## Building, testing, releasing

- [`docs/testing/TROUBLESHOOTING.md`](testing/TROUBLESHOOTING.md) — read it when a gate is red and the failure doesn't name your change. Indexed by symptom.
- [`docs/RELEASING.md`](RELEASING.md) — cutting a Mac or phone release, signing, notarization, auto-update.

## Work in progress and its history

- [docs/superpowers/specs/](superpowers/specs/) — design specs, one per milestone.
- [docs/superpowers/plans/](superpowers/plans/) — implementation plans.
- [docs/superpowers/notes/](superpowers/notes/) — audits, diagnoses, handoffs. The newest audit is `docs/superpowers/notes/2026-10-17-foundations-audit.md`.
- [`docs/history/README.md`](history/README.md) — narrative, provenance and rejected alternatives moved out of the `AREA.md` guides. Not required reading.

## The code, area by area

Each directory with an `AREA.md` asks you to read it before editing anything there.

- [`Packages/MaughamCore/Sources/MaughamCore/AREA.md`](../Packages/MaughamCore/Sources/MaughamCore/AREA.md) — the shared package both apps build on: a map of every file, its rules, and recipes.
- [`Maugham/OpLog/AREA.md`](../Maugham/OpLog/AREA.md) — the op log, the signed chain, the register and permits.
- [`Maugham/Stores/AREA.md`](../Maugham/Stores/AREA.md) — project and document stores, the project session that owns them, the typed mover, the `.maugham/` layout.
- [`Maugham/Editor/AREA.md`](../Maugham/Editor/AREA.md) — the editor coordinator and its fragile binding contract.
- [`Maugham/Publish/AREA.md`](../Maugham/Publish/AREA.md) — PDF and EPUB publishing, the department desk, imprints and editions.
- [`Maugham/Canvas/AREA.md`](../Maugham/Canvas/AREA.md) — the Plan persona's canvas.
- [`Maugham/Compiler/AREA.md`](../Maugham/Compiler/AREA.md) — checks, rounds, the editorial letter, the translation pipeline.
- [`Maugham/MCP/AREA.md`](../Maugham/MCP/AREA.md) — the MCP server and its tool catalogue.
- [`Maugham/Views/AREA.md`](../Maugham/Views/AREA.md) — the window, personas, the binder tree, posture surfaces.
- [`Maugham/Updates/AREA.md`](../Maugham/Updates/AREA.md) — the in-place updater.
- [`MaughamPhone/AREA.md`](../MaughamPhone/AREA.md) — the iPhone companion: storage seams, capture, reading, annotations, tripwires, releases.

Recipes — add a block kind, a Statement.Kind or a ProjectType: the Core area guide's Recipes section.
