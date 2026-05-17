# ReproLab

**Autonomous agent pipeline that reproduces ML papers and explores improvements.**

ReproLab takes a paper (PDF upload, arXiv ID, or DOI), reconstructs its implementation environment inside a Docker or RunPod sandbox, reproduces the core algorithm on the same dataset, launches parallel improvement agents through three verification gates, and emits a scientific benchmark report — a computed PaperBench-style rubric plus a statistical comparison against the paper's claimed results.

---

## Architecture

- **FastAPI backend** (`backend/`) — REST API + SSE event stream, agent orchestration, sandbox lifecycle
- **Next.js lab frontend** (`frontend/`) — live pipeline progress strip, agent timeline, gate chips, final report view
- **14-stage agent pipeline** — writes checkpoints to `<runs_root>/<project_id>/pipeline_state.json` (default `runs_root` is `./runs`; the dev launcher sets it to `logs/<launch-ts>/` so pipeline runs land alongside the server logs). Stages: ingest → paper-understanding → artifact-discovery → environment-detective → reproduction-planner → Gate 1 → baseline-implementation → experiment-runner → Gate 2 → improvement-selection → improvement-paths (parallel) → Gate 3 → research-map → complete
- **Three verification gates** — structured pass/fail with dynamic confidence thresholds and supervisor verification
- **Sandbox execution** — Docker (local, network/memory/CPU controlled) or RunPod GPU pods (remote, configurable GPU type/count/region)
- **Event-sourced state** — SQLite event store + CQRS projections; pipeline state persisted atomically at each stage

---

## Prerequisites

| Requirement | Version |
|---|---|
| Python | 3.11 or newer |
| Node.js | >=20.19.0 and <21, OR >=22.12.0 (Node 21 is excluded by `engines` in `package.json`) |
| Docker | Engine 26+ / Desktop 4.30+ |
| RunPod account | Required only for `--sandbox runpod` |

API keys required (at minimum one of):

- `ANTHROPIC_API_KEY` — for the Anthropic/Claude provider
- `OPENAI_API_KEY` — for the OpenAI provider

---

## Quick Start

### Option A — Docker Compose (recommended)

```bash
cp .env.example .env
# Edit .env: set ANTHROPIC_API_KEY and/or OPENAI_API_KEY
docker compose up --build
```

- Lab UI: http://localhost:3000/lab
- PaperBench UI: http://localhost:3000/paperbench
- Backend health: http://localhost:8000/health

### Option B — Local development

One-time setup:

```bash
python3.11 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r backend/requirements.txt

cd frontend && npm ci && cd ..
```

Required environment variables (copy from `.env.example` or set in shell):

```bash
# Minimum required
export ANTHROPIC_API_KEY=sk-ant-...    # or OPENAI_API_KEY for OpenAI provider

# Optional but strongly recommended
export REPROLAB_DEFAULT_SANDBOX=docker  # or runpod / local
export REPROLAB_RUNPOD_API_KEY=...      # required when sandbox=runpod
export REPROLAB_RUNPOD_SSH_KEY_PATH=~/.ssh/id_ed25519

# Where per-pipeline-run artifacts get written. Defaults to ./runs.
# scripts/dev.sh overrides this to logs/<launch-ts>/ so server logs and
# pipeline runs share one folder per server lifetime.
# export REPROLAB_RUNS_ROOT=runs

# Database (SQLite default — no setup needed)
# export REPROLAB_DATABASE_URL=sqlite:///reprolab.db
```

**Launch (recommended) — `scripts/dev.sh`**

```bash
./scripts/dev.sh
```

Creates `logs/<YYYYMMDD-HHMMSS>/`, starts `uvicorn` (FastAPI, :8000) and `npm run dev` (Next.js, :3000), and tees their stdout+stderr into `backend.log` / `frontend.log`. Sets `REPROLAB_RUNS_ROOT` to the same folder so any pipeline runs you kick off land at `logs/<launch-ts>/<project_id>/`. A `meta.json` records `started_at`, `ended_at`, pids, git sha, and the sandbox mode. Stop with Ctrl-C — the trap updates `meta.json` and frees the ports.

**Launch (manual fallback — two processes)**

```bash
# terminal 1: backend
.venv/bin/uvicorn backend.app:create_app --factory --reload --port 8000
# or, for RunPod preflight checks: ./start.sh

# terminal 2: frontend
cd frontend
REPROLAB_BACKEND_URL=http://127.0.0.1:8000 npm run dev
```

---

## Running a Reproduction

### Via the Lab UI

1. Open http://localhost:3000/lab
2. Upload a paper PDF (or paste an arXiv/DOI URL)
3. Choose provider (Anthropic / OpenAI), execution mode (efficient / max), and sandbox (docker / runpod / local)
4. Click **Start Run** — the pipeline strip shows each stage advancing in real time
5. Gate chips turn green (pass) or red (fail) as the three verification gates resolve
6. When the run reaches `complete`, click **View Report** to read the final benchmark report

_Screenshots: `localhost_3000_lab.png` and `Screenshot 2026-05-10 093252.png` at the repo root show the lab UI mid-run._

### Via the CLI

```bash
# Full SDK pipeline (uses LLM) — PDF, arXiv ID, or DOI all work
python -m backend.cli reproduce paper.pdf --provider anthropic --sandbox docker

# Key flags
#   --mode offline          deterministic, no LLM (for testing)
#   --mode sdk              LLM-powered (default)
#   --provider anthropic|openai
#   --verification-provider anthropic|openai   (separate model for gate verification)
#   --sandbox auto|local|docker|runpod
#   --execution-mode efficient|max
#   --n-paths 3             number of parallel improvement hypotheses
#   --max-usd 5.00          hard spend cap
#   --max-wall-clock 3600   wall-clock limit in seconds
#   --model claude-sonnet-4-6   override model
#   --seed 42               reproducible run

# Ingest only (no agent pipeline)
python -m backend.cli ingest 2512.24601          # arXiv ID
python -m backend.cli ingest paper.pdf

# Evaluate a completed run
python -m backend.cli eval <project_id> --paper-metrics '{"mean_reward": 500}'
```

---

## Where Results Land

When launched via `scripts/dev.sh`, one folder = one server lifetime:

```
logs/<launch-ts>/
├── backend.log         uvicorn stdout+stderr (tee'd live)
├── frontend.log        next dev stdout+stderr (tee'd live)
├── meta.json           started_at / ended_at / pids / git_sha / sandbox_mode
└── <project_id>/       one subfolder per pipeline run kicked off in this launch
```

Without `scripts/dev.sh` the pipeline writes to `./runs/<project_id>/` (the legacy default — override with `REPROLAB_RUNS_ROOT`). Each per-pipeline-run folder contains:

| File / Dir | Contents |
|---|---|
| `pipeline_state.json` | Full serialized pipeline state including all gate decisions |
| `final_report.json` | Computed benchmark report (structured) |
| `final_report.md` | Human-readable benchmark report |
| `assumption_ledger.json` | Every agent assumption with citations |
| `agent_telemetry.jsonl` | Per-invocation timing and token counts |
| `cost_ledger.jsonl` | Per-agent USD spend and token ledger |
| `Dockerfile` | Generated environment Dockerfile |
| `code/` | Reproduced baseline implementation |
| `hermes/` | Verification gate audit chain checkpoints |
| `raw_paper.pdf` | Stored copy of the input paper |

The **final report** (`final_report.md`) contains: reproduction fidelity score, paper-vs-reproduction metric delta table, computed PaperBench rubric (weight-aware), statistical rigor assessment, improvement path summaries, and a research map of promising directions and negative results.

---

## Testing

**Backend**

```bash
# All tests
.venv/bin/python -m pytest tests/

# With dev dependencies (parallel execution, rerun flaky tests)
pip install -r backend/requirements-dev.txt
.venv/bin/python -m pytest tests/ -n auto
```

**Frontend**

```bash
cd frontend

# Type-check (no Node version constraints)
npx tsc --noEmit

# Unit tests (requires Node >=20.19 <21 or >=22.12)
npm test
```

---

## Project Layout

```
backend/          FastAPI app, 14-stage agent pipeline, sandbox runtimes, evals
frontend/         Next.js lab UI: pipeline dashboard, agent timeline, report viewer
tests/            Python test suite (unit, integration, e2e)
docs/             Architecture notes, setup guide, deployment plan
logs/             Per-launch dev folders: backend.log + frontend.log + per-run prj_*/ (gitignored, written by scripts/dev.sh)
runs/             Legacy default per-run root when REPROLAB_RUNS_ROOT is unset (gitignored, mount as volume in prod)
third_party/      Vendored PaperBench bundles
docker/           Container entrypoint script
scripts/          dev.sh launcher, RunPod preflight, utility scripts
```

---

See [`docs/deployment.md`](docs/deployment.md) for production deployment instructions.
