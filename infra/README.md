# LearningHub — Dev Infrastructure

Two Docker Compose stacks:

| Stack | File | Services | When |
|---|---|---|---|
| **Main** | `docker-compose.yml` | PostgreSQL 16, MongoDB 7, Redis 7, RabbitMQ 4 (STOMP + management), MinIO (+ bucket init), MailHog | Always during dev |
| **Judge0** | `judge0/docker-compose.yml` | Judge0 CE server + workers + its own PG/Redis | Only when working on code questions (heavy) |

## Setup

```bash
# from the repo root — once:
cp infra/.env.example .env       # fill in secrets (never commit .env)
```

## Main stack

```bash
# from the repo root:
docker compose --env-file .env -f infra/docker-compose.yml up -d
docker compose -f infra/docker-compose.yml ps        # all should be healthy
docker compose -f infra/docker-compose.yml down      # stop (data kept in volumes)
```

Every variable has a dev-safe default, so the stack also starts without `.env` — but the backend expects the same values, so use one `.env` for both.

| Service | Endpoint | Console / notes |
|---|---|---|
| PostgreSQL | `localhost:5432` | db `learning_hub` |
| MongoDB | `localhost:27017` | |
| Redis | `localhost:6379` | |
| RabbitMQ | AMQP `localhost:5672` · STOMP `localhost:61613` | UI: http://localhost:15672 (user/pass from `.env`) |
| MinIO | S3 API `localhost:9000` | Console: http://localhost:9001 — `minio-init` auto-creates the app bucket |
| MailHog | SMTP `localhost:1025` | Inbox UI: http://localhost:8025 |
| Ollama | `localhost:11434` | **not containerized** — existing WSL install, see below |

### Ollama (existing WSL install)

Ollama is **not** part of the compose stack — the owner already runs it in WSL, and WSL2 forwards `localhost:11434` to Windows. Grading/chatbot use Ollama **cloud models** (`*-cloud`) that execute on ollama.com hardware through the same local API. One-time sign-in inside WSL:

```bash
ollama signin
# verify a cloud model is reachable:
ollama run gpt-oss:120b-cloud "hello"
# offline fallback (local model, no sign-in needed):
ollama pull qwen2.5:7b
```

Notes:
- The AI server can alternatively call `https://ollama.com` directly using `OLLAMA_API_KEY` from `.env` (key from https://ollama.com/settings/keys).
- If the AI server is ever containerized, point it at `http://host.docker.internal:11434` instead of `localhost` to reach the WSL Ollama from inside Docker.

## Judge0 stack

1. **Change both passwords** in `judge0/judge0.conf` first.
2. Start / stop:

```bash
docker compose -f infra/judge0/docker-compose.yml up -d
docker compose -f infra/judge0/docker-compose.yml down
```

3. Smoke test:

```bash
curl http://localhost:2358/languages          # list of runnable languages
```

**Windows / WSL2 caveat:** Judge0's isolate sandbox needs cgroup v1. If submissions stay in *Processing*, add to `%UserProfile%\.wslconfig`:

```ini
[wsl2]
kernelCommandLine = systemd.unified_cgroup_hierarchy=0 cgroup_no_v1=none
```

then `wsl --shutdown` and restart Docker Desktop.

Judge0 deliberately runs its **own** postgres/redis (stock CE layout) — do not point it at the main stack's databases.

## Prod notes

- MailHog is dev-only; prod uses **Brevo SMTP free tier** — swap `SMTP_*` values in `.env`, nothing else changes.
- Judge0 in prod: enable `AUTHN_HEADER`/`AUTHN_TOKEN` in `judge0.conf` and keep it on a private network.
- The AI server must never be publicly exposed — docker network + backend only.
