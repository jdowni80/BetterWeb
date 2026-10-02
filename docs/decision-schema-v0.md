# Decision schema v0 (draft)

Target runtime: `fastino/GLiNER2.5-Decide` via `gliner2.AutoExtractor` (local).

This is a **draft label set** for page / snippet judgment. Schemas should stay versioned and user-overridable.

## Questions

| Id | Type | Answers | Intent |
| --- | --- | --- | --- |
| `authorship_likeness` | single | `human_crafted`, `mixed`, `synthetic_filler`, `unknown` | Detect AI-slop-ish filler vs. crafted writing |
| `bot_spam` | single | `yes`, `no`, `uncertain` | SEO farms, scrapers, obvious automation |
| `propaganda_signal` | single | `clear`, `none`, `uncertain` | Flag clear political propaganda; default UX is badge, not hide |
| `malice` | single | `benign`, `scam_or_harm`, `uncertain` | Scams, malware bait, clearly harmful corners |
| `thought_quality` | ordinal | `1`–`5` | Specificity, argument, original observation |
| `niche_value` | single | `common`, `specialist_useful`, `rare_gem` | Discoverability boost for good small web |

## Suggested constraints

- If `bot_spam = yes` → prefer lower `thought_quality` / never treat as `rare_gem`
- If `malice = scam_or_harm` → hard demote in ranking regardless of relevance
- If `propaganda_signal = clear` → keep visible by default; attach flag for UI filters

## Ranking hooks (toy)

```text
score = relevance
      + w_q * thought_quality
      + w_n * niche_bonus(niche_value)
      - w_s * slop_penalty(authorship_likeness, bot_spam)
      - w_m * malice_penalty(malice)
# propaganda_signal affects badges / optional user filter, not silent deletion
```

## Notes

- GLiNER2.5-Decide does **not** explain or debate; it scores schema answers. Rubrics live in label descriptions + fine-tuning data.
- Start with short extracts (title + meta + lead paragraphs), not full HTML dumps.
- Keep “propaganda” narrow: **clear** propaganda, not “I disagree with this essay.”
- v0 runtime guard: if the model returns `propaganda_signal=clear` but the text has no political cue terms, demote to `uncertain` (zero-shot false positives on marketing filler). Fine-tuning should replace this.
