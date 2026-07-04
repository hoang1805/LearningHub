# LearningHub — System Architecture

LearningHub is a learning platform for **students, teachers, and admins**: a social core (profiles, friends, chat, groups, posts, feeds, contribution score), an exam engine (practice/exam modes, sections, 5 question types incl. code, anti-cheat, live monitoring), AI services (grading + study chatbot), and admin tooling.

## Repository structure (master project + sub-repos)

`LearningHub/` (root) is the **master git repo**; each app is its own independent git repo attached as a **git submodule**:

```
LearningHub/                 ← master repo (docs + infra + .gitmodules)
├── docs/                    ← PLAN.md, ARCHITECTURE.md, DATABASE.md, CONVENTIONS.md
├── infra/                   ← docker-compose.yml, judge0/, .env.example
├── LearningHubBackend/      ← submodule — Spring Boot 3.5 / Java 21 / MyBatis
├── LearningHubFE/           ← submodule — React 19 / Vite / TS / MUI v7
└── ai-server/               ← submodule — Python 3.12 / FastAPI / LangChain / LangGraph
```

Each sub-repo has its own history, branches, and CI; the master repo pins submodule commits and holds cross-cutting docs/infra.

## Components & ports (dev)

| Component | Tech | Port | Role |
|---|---|---|---|
| Frontend | React 19 + Vite | **5175** (`server.port` in vite.config.ts must match BE CORS) | SPA |
| Backend | Spring Boot 3.5.5 + MyBatis | 8080 | REST + STOMP WebSocket, single auth authority |
| AI server | Python 3.12, FastAPI + LangChain + LangGraph | 8000 | Grading worker + chatbot; never publicly exposed (docker network + BE only) |
| Ollama | **existing WSL install** (not containerized; WSL2 forwards `localhost:11434`) | 11434 | LLM runtime signed into **Ollama Cloud** (`OLLAMA_API_KEY`): grading/chatbot use `-cloud` models executing on ollama.com hardware through the same local API; small local models remain the offline fallback. From a container use `host.docker.internal:11434` |
| PostgreSQL | Docker | 5432 | Relational system of record |
| MongoDB | Docker | 27017 | Append-heavy documents |
| Redis | Docker | 6379 | Cache, realtime state, leaderboards |
| RabbitMQ | Docker (`rabbitmq_stomp` + management plugins) | 5672 (AMQP) / 61613 (STOMP) / 15672 (UI) | Grading job queues (code + AI) **and** STOMP broker relay for WebSocket fan-out |
| Judge0 CE | Docker (own compose; bundles its own PG/Redis — do not share) | 2358 | Code execution sandbox |
| MinIO | Docker | 9000 (API) / 9001 (console) | S3-compatible file storage |
| MailHog | Docker (dev) | 1025 / 8025 | SMTP capture; **prod: Brevo SMTP free tier** (.env-only swap) |

## Communication

```
FE ──REST /api/** (cookies, withCredentials)──────────▶ BE
FE ──WS /ws (STOMP, cookie auth)──▶ BE ──STOMP relay──▶ RabbitMQ (61613)
BE ──AMQP publish grading.ai.jobs─────▶ RabbitMQ ─────▶ AI server (aio-pika consumer)
BE ──AMQP publish grading.code.jobs───▶ RabbitMQ ─────▶ BE CodeJudgeWorker ──REST──▶ Judge0
AI ──POST /internal/ai/v1/grading-callback (HMAC)─────▶ BE
FE ──SSE chatbot stream───▶ BE ──HTTP SSE──▶ AI server
AI ──HTTP──▶ Ollama
BE ──MyBatis──▶ Postgres   BE ──Spring Data Mongo──▶ Mongo   BE ──Lettuce──▶ Redis
```

## Real-time: Spring WebSocket + STOMP with RabbitMQ broker relay

FE keeps a single WebSocket to BE (`/ws`, cookie JWT auth on the handshake) using `@stomp/stompjs` v7. BE relays `/topic` + `/queue` destinations to RabbitMQ via `enableStompBrokerRelay` (`rabbitmq_stomp` plugin, port 61613). Per-user queues and destination ACLs are enforced by a `ChannelInterceptor` on SUBSCRIBE. Durable broker, multi-node ready.

| Destination | Purpose |
|---|---|
| `/user/queue/notifications` | notification push |
| `/user/queue/chat` | new-message badge events |
| `/topic/conversation/{id}` | live messages, typing, read receipts |
| `/app/chat.send`, `/app/chat.typing` | FE→BE chat |
| `/topic/exam/{examId}` | announcements, time changes, force-submit |
| `/topic/exam/{examId}/monitor` | live progress + proctor events (scorers/managers) |
| `/app/exam.heartbeat` | attempt heartbeat (progress, focus state) |

## Judging queues — ALL slow grading is queue-based (RabbitMQ), never inline

On submit, cheap graders (one-choice, multi-choice, short-answer) run synchronously; **code and AI grading are enqueued**.

Topology: direct exchange `grading` → queues `grading.code.jobs` / `grading.ai.jobs`, each with dead-letter exchange `grading.dlx` → `grading.code.dlq` / `grading.ai.dlq`; retry via delay queue (TTL + `x-death` count) then DLQ. Persistent messages + publisher confirms — jobs survive restarts. Same JSON envelope everywhere: `{job_id, attempt_answer_id, payload, enqueued_at}`.

### Code queue — BE `CodeJudgeWorker` pool (`@RabbitListener`, concurrency 2–4)
1. The submission endpoint only persists `code_submissions(status=QUEUED)` + publishes, then returns immediately — request threads never wait on Judge0.
2. The worker submits to Judge0 (`POST /submissions/batch`), polls tokens, writes per-test results + score into `code_submissions` / `grading_records(AUTO)`, and pushes live status to the candidate and the monitor topic.
3. Judge0 down/timeout → nack → retries with backoff (configurable `GRADING_MAX_RETRIES`, default 3) → DLQ, submission `FAILED`, exam manager notified; admin can requeue.

### AI queue — Python consumer (aio-pika, prefetch 1)
1. **Dispatch**: BE publishes `{job_id (= grading_record id), question, rubric/config, student answer, prompt_version}`.
2. **Result**: AI calls `POST /internal/ai/v1/grading-callback` on BE — HMAC-SHA256 signed (`X-AI-Signature`), idempotent on job_id → BE persists the grading record, recomputes the attempt score, notifies via STOMP.
3. **Failure** (model disconnected / Ollama Cloud unreachable / timeout): retries with backoff up to configurable `AI_MAX_RETRIES` (default 3) → DLQ + `FAILED` callback → answer flagged for manual grading and the **teacher/exam manager receives a push notification**. Admin can requeue the DLQ.

Shared admin ops: `GET /api/admin/v1/grading/jobs?queue=code|ai&status=` (depths + DLQ via RabbitMQ management API) and `POST /api/admin/v1/grading/jobs/requeue`. Attempt totals finalize only when no QUEUED/PENDING jobs remain for the attempt.

### Chatbot
Synchronous SSE proxied **FE → BE → AI** (auth + rate limiting stay in one place; AI server is never publicly reachable).
AI server endpoints: `POST /v1/chat` (SSE), `POST /v1/grade`, `GET /health`, `GET /models`.

## Dev infrastructure

- `infra/docker-compose.yml`: postgres, mongo, redis, rabbitmq (stomp + management plugins via `enabled_plugins` file), minio (+ bucket-init), mailhog — all with healthchecks. Ollama runs natively in WSL (not in compose).
- `infra/judge0/docker-compose.yml`: stock Judge0 CE (isolated stack).
- BE / FE / AI server run on the host during dev for hot reload.
- Root `.env` feeds compose + Spring (`spring.config.import=optional:file:.env[.properties]`) + FastAPI settings. See `infra/.env.example`.
