# LearningHub

A learning platform for **students, teachers, and admins** — learn, practice, and take exams together.

- **Social**: profiles, friends, 1-1 & group chat, learning groups, posts/comments/reactions, global + group feeds, contribution score & leaderboards
- **Exams**: practice mode (relaxed, instant answers/explanations) and exam mode (timed, anti-cheat tracking, live monitoring, announcements, mid-exam time control); sections with 5 question types — one choice, multiple choice (configurable scoring), short answer, long answer, and code (sandboxed via Judge0, Monaco editor)
- **Grading**: auto-grading for objective types; queue-based code judging (Judge0) and AI grading (Ollama Cloud via LangChain); manual grading by scoring members with AI override
- **AI**: study-assistant chatbot with conversation history
- **Admin**: user management, bans, teacher-role approval, server/AI status & metrics

## Repository layout (master repo + submodules)

| Path | What | Stack |
|---|---|---|
| [LearningHubBackend/](LearningHubBackend/) | REST API + WebSocket | Spring Boot 3.5, Java 21, MyBatis, PostgreSQL/MongoDB/Redis/RabbitMQ |
| [LearningHubFE/](LearningHubFE/) | Web app | React 19, Vite, TypeScript, MUI v7, Tailwind v4, TanStack Query |
| [ai-server/](ai-server/) | AI grading + chatbot | Python 3.12, FastAPI, LangChain, LangGraph, Ollama Cloud |
| [infra/](infra/) | Dev environment | docker-compose (PG, Mongo, Redis, RabbitMQ, MinIO, MailHog, Ollama), Judge0 CE |
| [docs/](docs/) | Design docs | see below |

Clone with submodules:

```bash
git clone --recurse-submodules <repo-url>
# or, after a plain clone:
git submodule update --init --recursive
```

## Documentation

| Doc | Content |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | Master plan: phases, task breakdown (P0-* … P4-*), decided defaults, risks |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components & ports, communication, realtime (STOMP/RabbitMQ), judging queues, AI pipeline |
| [docs/DATABASE.md](docs/DATABASE.md) | Data placement (PG/Mongo/Redis), all schemas, contribution-score formula |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md) | Backend/frontend/AI/git conventions, API style guide, MyBatis rules |

## Quick start (dev)

```bash
# 1. Configure environment
cp infra/.env.example .env        # then fill in secrets

# 2. Start infrastructure
docker compose -f infra/docker-compose.yml up -d
# optional — only when working on code questions:
docker compose -f infra/judge0/docker-compose.yml up -d

# 3. Backend (http://localhost:8080)
cd LearningHubBackend && ./mvnw spring-boot:run

# 4. Frontend (http://localhost:5175)
cd LearningHubFE && npm install && npm run dev

# 5. AI server (http://localhost:8000)
cd ai-server && uv sync && uv run fastapi dev
```

Dev consoles: RabbitMQ `http://localhost:15672` · MinIO `http://localhost:9001` · MailHog `http://localhost:8025` · Swagger UI `http://localhost:8080/swagger-ui` (dev profile).
