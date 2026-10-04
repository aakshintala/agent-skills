# Agent instructions

## Agent skills

delegate lives in switchyard and shares its setup in `../docs/agents/`.

- **Issues and specs**: switchyard's GitHub Issues, labelled `delegate`. Before publishing or fetching a ticket, or running `/wayfinder`, read `../docs/agents/issue-tracker.md`. Issue and PR numbers before the merge into switchyard are on `aakshintala/delegate`.
- **Triage labels**: meanings in `../docs/agents/triage-labels.md`.
- **Domain docs**: before exploring an area or naming a domain concept, read `../docs/agents/domain.md`.
- **Paths**: run `cargo` and `scripts/` from `delegate/`. The skill is `../skills/delegate/SKILL.md`.

## Parser fixtures

- `tests/fixtures/contract/<backend>/`: curated streams that parser tests assert on. Record one with `FIXTURE_KIND=contract scripts/record.sh BACKEND MODEL NAME < prompt`.
- `tests/fixtures/recorded/<backend>/`: the raw archive of real runs, which tests only parse. Never edit these by hand. `scripts/record.sh` writes here by default.
- When a ticket needs a new contract fixture, the orchestrator records it before the lane starts, because recording runs a real model.
