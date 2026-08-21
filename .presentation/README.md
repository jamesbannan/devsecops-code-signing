# Presentation contract

`facts.yaml` is the structured description of this repository that slide decks
consume. It exists so a talk about these demos never has to restate them by
hand — change a demo, change the facts, and the slides follow.

## Who consumes it

[`jamesbannan/presentations`](https://github.com/jamesbannan/presentations),
deck `zero-friction-devsecops`. Its `content.yaml` does a sparse shallow fetch
of this repository and converts `facts.yaml` into JSON the deck imports. The
deck holds no copy of the demo content.

## What is in it

| Key | Describes |
| --- | --- |
| `architecture` | Cards mirroring `docs/architecture.md` — what gets deployed |
| `demos` | One entry per `demos/demo[1-6]-*/run.sh`: `dir`, `title`, `theme`, `intro`, `steps`, `watch` |

Text fields accept lightweight inline markdown: `` `code` ``, `**bold**`,
`*italic*`.

Slide chrome — layout, fonts, colours, per-event details — belongs to the deck,
not here. This file only describes what is true about the repository.

## Keeping it honest

```bash
bash scripts/check-presentation.sh
```

Run in CI by `.github/workflows/presentation-contract.yml` whenever `demos/`,
`docs/architecture.md` or this directory changes. It verifies the YAML parses,
the required fields are present, and — the part that matters — that every
`demos.<name>.dir` still points at a real demo with a `run.sh`.

Because the deck lives in another repository, nothing here fails at demo
runtime when the facts drift. This check is the only thing standing between a
demo rename and a talk that describes code that no longer exists.
