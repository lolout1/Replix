# Deepinvent.ai — Research, Comparison vs ReproLab, and Infra Plan

## 1. What Deepinvent.ai is

Deepinvent.ai is an AI startup (founded 2025, US-based, ~$200k pre-seed from Antler on 2025-03-25) positioning itself as "the application layer for innovation." Their stated pipeline:

- Compile scientific papers, patents, industry data, and trend signals into a **knowledge graph**.
- Use deep learning to reveal latent relationships and identify **"whitespace"** (low-density regions of the IP/idea space).
- **Generate invention variants** in the whitespace, evolved with a genetic-algorithm-style loop.
- Produce a **patent draft** for a human IP professional to review.

Public materials and the founder describe a UX where a user enters an idea, the system surfaces adjacent prior art, the user picks an invention from the whitespace, refines it in-app, and receives provisional patent language.

Their terms-of-service explicitly state users must manually review every AI output — patentability is high-stakes and AI outputs can be persuasive without being reliable.

### Traction / customers

- Austin startups profile claims beta users include Google, Amazon, Microsoft, OpenAI, and Genentech, and that ~20,000 inventions have been generated.
- Treat the named-company list as **possible beta participants**, not confirmed paying customers — no first-party case studies from those companies were found.
- Positioning: B2B subscription, targeting startups, enterprise R&D, and IP professionals.

### Credibility read

Strongest use case is **ideation + prior-art acceleration**, not a replacement for patent counsel. Key open questions:

- Is prior-art coverage actually better than general search tools?
- How much novelty does it add beyond summarization?
- How often do outputs hold up under attorney review?

---

## 2. ReproLab (this repo) vs Deepinvent — they are different categories

| | **ReproLab** | **Deepinvent.ai** |
|---|---|---|
| Input | ML paper (PDF / arXiv / DOI) | Idea or research domain |
| Core action | **Reproduces** the paper, then explores improvements | **Generates** novel inventions, drafts patents |
| Output | PaperBench-style rubric, fidelity score, metric delta vs claims, statistical comparison, improvement paths, research map | Patent draft, invention variants, whitespace analysis |
| Pipeline | 14-stage agent pipeline → 3 verification gates → final report | KG synthesis → GA variants → draft IP |
| Execution | Docker / RunPod GPU sandbox (real code runs) | No code execution — text/IP synthesis |
| User | ML researchers, eval teams, paper-claim auditors | R&D + IP / patent professionals |
| Verifiability | **Empirical** (code either reproduces or doesn't) | **Editorial** (lawyer reviews the draft) |

### Where they overlap

- Both ingest scientific literature and run multi-agent pipelines.
- Both emit a "research map" of directions.
- `improvement-selection` + `improvement-paths` resemble Deepinvent's "variants in whitespace" — but ReproLab **executes** them in a sandbox and measures deltas. Deepinvent stays in the document layer.

### Where ReproLab is genuinely differentiated

1. **Empirical grounding.** Output is a reproduction score against ground truth.
2. **Sandbox execution + cost ledger.** Docker/RunPod runtime, per-agent USD spend, telemetry, audit gates.
3. **Audit chain.** `hermes/` checkpoints + assumption ledger with citations.
4. **PaperBench-shaped evaluation.**

### Strategic read

- **No customer overlap.** Deepinvent sells to IP/legal/R&D-strategy. ReproLab sells to ML researchers, eval teams, AI-safety labs, paper-claim auditors.
- Closest analogs to ReproLab: **FutureHouse, METR, OpenAI PaperBench, Sakana AI Scientist** — not Deepinvent.
- The differentiator — *running the code and measuring the gap* — is exactly what the patent-AI category structurally cannot do.

---

## 3. Where ReproLab is lacking for "autonomous ML research"

Compared to Sakana AI Scientist v2 (ideation → experiments → autoreview, ICLR-workshop-accepted paper), FutureHouse Aviary (trained agents on multi-step science tasks), and PaperBench (the eval ReproLab is shaped around) — ReproLab is excellent at *one paper, deeply reproduced*, but missing the corpus layer that turns reproduction into research.

### Honest gap list

1. **No cross-run memory.** Every run is hermetic. Run #87 can't tell you "we already tried this trick on this dataset in run #12." `runs/<id>/` is a graveyard.
2. **No corpus / world-model.** No persistent KG of papers, methods, datasets, metrics, results. Re-ingest from zero every time.
3. **No ideation loop.** Humans pick the paper. Sakana v2 *generates* what to study; ReproLab only executes.
4. **Improvement paths are intra-paper.** `improvement-selection` invents tricks locally — can't say "apply LoRA-MoE from paper X to the RL setup of paper Y" because it doesn't know X exists.
5. **No automated reviewer / novelty gate.** The 3 gates check reproduction fidelity, not *contribution against literature*.
6. **No negative-results registry.** Failed runs vaporize. This is the biggest unclaimed moat — Sakana doesn't have it either.
7. **No long-context recursive reasoning** over big paper bundles. RLM is the right pattern; not yet wired in.
8. **No method/code reuse across runs.** Every Dockerfile is bespoke; shared preprocessing/dataloaders aren't promoted to a library.

---

## 4. Layering Deepinvent's infra on top of ReproLab (ML-research flavored)

Three new layers above the current pipeline, each reusing existing components.

### Layer 1 — Corpus / Knowledge Graph
(their "knowledge graph" → ReproLab's research graph)

- New `backend/corpus/` service. Ingest **OpenAlex + Semantic Scholar + Papers With Code + arXiv + GitHub** (`paper → repo`).
- Schema: `Paper, Method, Dataset, Benchmark, Metric, Claim, Code, Author, ReproductionRun, Result, Contradiction`.
- Storage: **pgvector** with SPECTER2 / GTE-large embeddings + lightweight graph view in Postgres (skip Neo4j v0).
- Every completed ReproLab run **writes back** to this graph as a `ReproductionRun` with verified `Result` edges.

### Layer 2 — Research Director
(their "GA variants" → empirical recombination)

- New `backend/agents/research_director.py`. Meta-agent that queries Layer 1 and produces hypotheses of the form `(method M, dataset D, expected delta Δ)`.
- "Whitespace" reframed for ML: `method × dataset` cells with no published result; papers with zero independent reproductions; contradicted claims.
- Genetic step = LLM mutate/crossover over hypotheses, **fitness = novelty (graph distance) × feasibility (cost + compute under budget) × expected signal**.
- Each surviving hypothesis becomes a ReproLab run — the current 14-stage pipeline is the *worker*, unchanged.

### Layer 3 — Recursive cognition (RLM)

- `backend/agents/recursive_reader.py`. Top-level model never sees the full PDF/codebase; it dispatches sub-calls (Claude/OpenAI sub-agents) that read scoped chunks and return distilled facts. Substrate already exists via context-mode.
- Use it inside `paper-understanding`, `artifact-discovery`, and the new `corpus-retrieve` stage so multi-paper bundles don't blow context.

---

## 5. How Hermes + the existing agent stack absorb this

- **Hermes audit chain** stops being per-run; becomes the **global claim ledger** — every claim, every reproduction verdict, every contradiction. Source of truth for the graph and the defensibility layer.
- **Existing agents** keep their stage shape, gain two new neighbors: `corpus-retrieve` (prepended) and `corpus-update + automated-reviewer` (appended as Gate 4).
- **Resilience / budget layer** governs Layer 2 too — Research Director can't spawn runs without passing the same cost gates.

---

## 6. Concrete v0 — ~3 weeks

1. Stand up `corpus/` with OpenAlex + Papers With Code ingest → pgvector + SPECTER2 embeddings.
2. Add `corpus-retrieve` + `corpus-update` stages to the pipeline; backfill all past `runs/` into the graph.
3. Build `research_director` in one mode: "given a seed paper, propose 5 reproduce-then-extend hypotheses, ranked."
4. Add **Gate 4**: automated-reviewer (novelty vs corpus + significance vs PaperBench rubric).
5. Promote Hermes from per-run JSON to a global `claims.db` event store.
6. Ship `recursive_reader` and route `paper-understanding` through it.

---

## 7. Bottom line — the unique triple

Closest analogs are Sakana, FutureHouse, METR, OpenAI PaperBench — not Deepinvent. The differentiator vs each of them:

- **Sakana AI Scientist v2** — ideates but reproduces shallowly.
- **FutureHouse Aviary** — trains agents but isn't reproduction-shaped.
- **Deepinvent** — never runs code.

ReproLab alone can marry:

1. **Empirical reproduction in a sandbox** (current strength)
2. **A corpus-level hypothesis engine** (Layers 1 + 2 above)
3. **A public negative-results registry** (Hermes promoted to global)

That triple is unclaimed.

---

## Sources

- https://deepinvent.ai
- https://deepinvent.ai/terms-of-service
- https://www.preqin.com/data/profile/asset/deepinvent-inc-/791286
- https://www.austinstartups.com/companies/deepinvent-inc
- https://pitch.vc/companies/deepinvent-inc
- https://www.linkedin.com/company/deepinvent-ai
- https://openai.com/index/paperbench/ — OpenAI PaperBench
- https://www.futurehouse.org/research-announcements/aviary — FutureHouse Aviary
- https://sakana.ai/ai-scientist-first-publication/ — Sakana AI Scientist v2 (ICLR workshop accepted paper)
- https://github.com/SakanaAI/AI-Scientist-v2
