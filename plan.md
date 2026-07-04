# LearningHub — Master Development Plan

## Context

LearningHub is a personal-project learning platform for students, teachers, and admins: a social core (profiles, friends, chat, groups, posts, feeds, contribution score) plus an exam engine (practice/exam modes, sections, 5 question types incl. code with Judge0, anti-cheat tracking, live monitoring) plus AI services (grading of short/long answers, study chatbot) and admin tooling.

**What exists today:**
- `LearningHubBackend/` — Spring Boot 3.5.5, Java 21, **MySQL + Spring Data JPA** (both to be replaced), JWT-in-cookies auth with single-active-session fingerprinting, Bucket4j throttling. Implemented: auth (login/register/logout/refresh), users, groups (members/invitations/requests/token-join), posts/comments/votes. Consistent pattern per aggregate: `XxxService` + `XxxQuery` + `XxxReader` + `XxxListener` + `XxxACL`; `BaseResponse{success,message,data,code}` always HTTP 200; DTOs `<Entity>Release`/`<Entity>ReleaseCompact` via `Releasable<T,C>`; Long ids + epoch-millis timestamps. Has its own `.git` (kept).
- `LearningHubFE/` — React 19 + Vite 7 + TS strict, **MUI v7** (themed, primary `#2463eb`) + Tailwind v4, Redux Toolkit, axios with refresh interceptor. Only login flow exists; `ProtectedRoutes`/`MainLayout` scaffolded but unused.

**Decisions locked:** PostgreSQL + MongoDB + Redis · **MyBatis (not JPA)** for the relational layer · keep MUI v7 · Judge0 CE self-hosted for code execution · Python AI server (FastAPI + Ollama + LangChain + LangGraph) · **master repo + sub-repos structure** · plan/design docs live in `LearningHub/docs/` · build order: Foundation → Social → Exams → AI → Admin.

**Known bugs to fix in foundation** (found during exploration):
1. `PostService.vote/unvote` uses `ObjectType.COMMENT` instead of `POST`
2. `CommentController.vote` missing `@RequestBody`
3. Group membership stored redundantly (`Group.members` JSON + `GroupMember` rows) with inconsistent arg order in `GroupListener.onJoined`
4. `GroupRequestService.remove(groupId, userId)` calls `getById(groupId)` (treats groupId as request id)
5. `Group.addMember` capacity guard inverted
6. `updatedAt` never advances on edits
7. Secrets committed in `application.properties`
8. FE stores JWT in localStorage while BE issues httpOnly cookies (two divergent auth paths)
9. `vite.config.ts` has no `server.port` (defaults 5173) but BE CORS allows only `http://localhost:5175`

## Repository Structure (master project + sub-repos)

`LearningHub/` (root) becomes the **master git repo**; each app is its **own independent git repo**, attached to the master as a **git submodule**:

```
LearningHub/                 ← master repo (git init; owns docs + infra + .gitmodules)
├── docs/                    ← PLAN.md, CONVENTIONS.md, ARCHITECTURE.md, DATABASE.md
├── infra/                   ← docker-compose.yml, judge0/, .env.example
├── LearningHubBackend/      ← submodule (existing .git kept)
├── LearningHubFE/           ← submodule (git init if not already a repo)
└── ai-server/               ← submodule (new Python project, own repo)
```

- Each sub-repo has its own history, branches, and CI; the master repo pins submodule commits and holds cross-cutting docs/infra.
- Conventional Commits everywhere; branches `feat/P1-4-friends-api`; task ids (P0-3…) referenced in commit messages.

## Documentation deliverables (written to `LearningHub/docs/` in P0-1)

| File | Content |
|---|---|
| `docs/PLAN.md` | This plan (phases, task tables, risks) |
| `docs/ARCHITECTURE.md` | §1 system architecture + communication + realtime + AI pipeline |
| `docs/DATABASE.md` | §3 schemas (PG tables, Mongo collections, Redis keys) + data placement |
| `docs/CONVENTIONS.md` | §5 BE/FE/git conventions, API style guide, MyBatis mapper rules |

---

## 1. System Architecture

### Components & ports (dev)

| Component | Tech | Port | Role |
|---|---|---|---|
| Frontend | React 19 + Vite | **5175** (set `server.port` in vite.config.ts to match BE CORS) | SPA |
| Backend | Spring Boot 3.5.5 + MyBatis | 8080 | REST + STOMP WebSocket, single auth authority |
| AI server | Python 3.12, FastAPI + LangChain + LangGraph | 8000 | Grading worker + chatbot; never publicly exposed (docker network + BE only) |
| Ollama | Docker | 11434 | LLM runtime signed into **Ollama Cloud** (`OLLAMA_API_KEY`): grading/chatbot use `-cloud` models that execute on ollama.com hardware through the same local API; small local models stay available as offline fallback |
| PostgreSQL | Docker | 5432 | Relational system of record |
| MongoDB | Docker | 27017 | Append-heavy documents |
| Redis | Docker | 6379 | Cache, realtime state, leaderboards |
| RabbitMQ | Docker (`rabbitmq_stomp` + management plugins) | 5672 (AMQP) / 61613 (STOMP) / 15672 (UI) | Grading job queues (code + AI) **and** STOMP broker relay for WebSocket fan-out |
| Judge0 CE | Docker (own compose, bundles its own PG/Redis — do not share) | 2358 | Code sandbox |
| MinIO | Docker | 9000/9001 | S3-compatible file storage |
| MailHog | Docker (dev) | 1025/8025 | SMTP capture (forgot-password); **prod: Brevo SMTP free tier** (300/day — swap is .env-only since we use spring-mail) |

### Communication

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

### Real-time: Spring WebSocket + STOMP with **RabbitMQ broker relay**, FE `@stomp/stompjs` v7
FE keeps a single WS to BE (`/ws`, cookie JWT auth on handshake); BE relays `/topic` + `/queue` destinations to RabbitMQ via `enableStompBrokerRelay` (`rabbitmq_stomp` plugin, port 61613). Per-user queues + destination ACLs via `ChannelInterceptor` on SUBSCRIBE. Durable broker, multi-node ready — no simple-broker single-node limitation.

| Destination | Purpose |
|---|---|
| `/user/queue/notifications` | notification push |
| `/user/queue/chat` | new-message badge events |
| `/topic/conversation/{id}` | live messages, typing, read receipts |
| `/app/chat.send`, `/app/chat.typing` | FE→BE chat |
| `/topic/exam/{examId}` | announcements, time changes, force-submit |
| `/topic/exam/{examId}/monitor` | live progress + proctor events (scorers/managers) |
| `/app/exam.heartbeat` | attempt heartbeat (progress, focus state) |

### Judging queues — ALL slow grading is queue-based (RabbitMQ), never inline
On submit, cheap graders (one-choice, multi-choice, short-answer) run synchronously; **code and AI grading are enqueued** on RabbitMQ. Topology: direct exchange `grading` → queues `grading.code.jobs` / `grading.ai.jobs`, each with dead-letter exchange `grading.dlx` → `grading.code.dlq` / `grading.ai.dlq`; retry via delay queue (TTL + `x-death` count, max 3) then DLQ. Persistent messages + publisher confirms — jobs survive restarts. Same JSON envelope everywhere (`job_id`, `attempt_answer_id`, payload, `enqueued_at`).

**Code queue** — consumed by a BE `CodeJudgeWorker` pool (`@RabbitListener`, concurrency 2–4):
1. Submission endpoint only persists `code_submissions(status=QUEUED)` + publishes, returns immediately — request threads never wait on Judge0.
2. Worker submits to Judge0 (`POST /submissions/batch`), polls tokens, writes per-test results + score into `code_submissions`/`grading_records(AUTO)`, pushes live status to the candidate (`/user/queue/notifications`) and monitor topic.
3. Judge0 down/timeout → nack → retries w/ backoff (configurable `GRADING_MAX_RETRIES`, default 3) → DLQ, submission `status=FAILED`, exam manager notified; admin can requeue.

**AI queue** — consumed by the Python server (aio-pika, prefetch 1):
1. **Dispatch**: BE publishes — payload: job_id (= grading_record id), question, rubric/config, student answer, prompt_version.
2. **Result**: AI calls `POST /internal/ai/v1/grading-callback` on BE, HMAC-SHA256 signed (`X-AI-Signature`), idempotent on job_id → BE persists grading_record, recomputes score, notifies via STOMP.
3. **Failure** (model disconnected / Ollama Cloud unreachable / timeout): retries w/ backoff up to configurable `AI_MAX_RETRIES` (default 3) → DLQ + `status=FAILED` callback → answer flagged for manual grading and **teacher/exam manager receives a push notification**. Admin can requeue DLQ.

Both queues share admin ops: `GET /api/admin/v1/grading/jobs?queue=code|ai&status=` (depths + DLQ contents via RabbitMQ management API) and `POST /api/admin/v1/grading/jobs/requeue` {queue, job_ids[]} (DLQ → main). Attempt totals finalize only when no QUEUED/PENDING jobs remain for the attempt (`grading_status` on `attempt_answers` drives this).

**Chatbot**: synchronous SSE proxied FE → BE → AI (auth/rate-limit in one place).
AI server endpoints: `POST /v1/chat` (SSE), `POST /v1/grade`, `GET /health`, `GET /models`.

### Dev infra
`infra/docker-compose.yml`: postgres, mongo, redis, rabbitmq (stomp + management plugins via `enabled_plugins` file), minio (+bucket init), mailhog, ollama — with healthchecks. `infra/judge0/docker-compose.yml`: stock Judge0 CE. BE/FE/AI run on host for hot reload. Root `.env` feeds compose + Spring (`spring.config.import=optional:file:.env[.properties]`) + FastAPI settings.

---

## 2. Data Placement

| Store | Data | Why |
|---|---|---|
| **PostgreSQL** | users, profiles, sessions, tokens, friendships, groups+membership, posts, comments, votes, files metadata, contribution events+score, role requests, moderation, ALL exam tables | FKs, transactions — exam scoring needs constraint-grade integrity. Flyway-managed, MyBatis-accessed. |
| **MongoDB** | chat_conversations, chat_messages, notifications, proctor_events (anti-cheat log), ai_conversations/ai_messages + LangGraph checkpoints | High-volume append-mostly, flexible payloads, TTL retention; keeps PG lean. |
| **Redis** | presence, leaderboards (ZSET), attempt deadlines (ZSET for auto-submit sweeper), unread counters, daily contribution caps, rate-limit buckets, caches | Ephemeral/derivable; everything rebuildable from PG/Mongo. |
| **RabbitMQ** | grading job queues (`grading.code.jobs`, `grading.ai.jobs` + DLQs) and STOMP relay traffic | Durable, ack-based delivery with DLX; doubles as the WS broker so realtime survives multi-node. |

BE dependency changes: **remove** `spring-boot-starter-data-jpa`, `spring-boot-starter-data-rest`, `mysql-connector-j`; **add** `org.postgresql:postgresql`, `mybatis-spring-boot-starter` 3.x, `flyway-core` + `flyway-database-postgresql`, `spring-boot-starter-data-mongodb`, `-data-redis`, `-websocket`, `-amqp` (RabbitMQ), `-validation`, `-mail`, `-actuator`, `springdoc-openapi-starter-webmvc-ui`, `io.minio:minio`, `io.projectreactor.netty:reactor-netty` (STOMP relay TCP client).

### MyBatis ground rules (→ CONVENTIONS.md)
- **Flyway owns the schema** (MyBatis has no DDL generation): `V{n}__desc.sql`, applied on boot.
- Mapper interfaces in `repositories/<aggregate>/` (keeping the existing package role), **XML mappers** in `resources/mappers/<aggregate>/*.xml` for anything beyond trivial CRUD; annotations allowed for one-liners.
- Models become plain POJOs (strip JPA annotations, keep Lombok + `Releasable`); enums map as `VARCHAR` via default `EnumTypeHandler`.
- **TypeHandlers** replace JPA converters: `JsonbMapTypeHandler` (`Map<String,Object>` ↔ JSONB), `JsonbLongListTypeHandler` (`List<Long>` ↔ JSONB), `StringArrayTypeHandler` (tags).
- Identity ids via `useGeneratedKeys="true" keyProperty="id"`; UUID (Token) generated in code with existing `UuidUtil.v7()`.
- Timestamps: a MyBatis `Interceptor` auto-fills `created_at` on insert and `updated_at` on update (fixes bug 6 uniformly).
- Pagination: keyset (cursor) SQL, no offset paging, no PageHelper.
- The `XxxQuery` classes keep their role — they wrap mappers instead of JpaRepositories, so services/ACLs don't change shape.

---

## 3. Database Schemas

Keep **Long identity ids + epoch-millis** in PG (matches BaseModel/Release code). Mongo uses ObjectId (time-ordered → doubles as pagination cursor).

### 3.1 PG — existing tables recreated in Flyway `V1` (with fixes)
`users`, `sessions`, `tokens`, `votes`, `groups` (**drop `members` JSON column** — group_members becomes single source of truth), `group_members`, `group_invitations`, `group_requests`, `posts`, `comments`.
`users` additions: `status (ACTIVE|BANNED)`, `banned_until`, `contribution_score NUMERIC(12,2)`, `lifetime_points NUMERIC(12,2)`.

### 3.2 PG — new tables

**Social/platform**

| Table | Key columns |
|---|---|
| `user_profiles` | user_id PK→users, avatar_file_id, cover_file_id, bio, school, birthday, links JSONB |
| `friendships` | requester_id, addressee_id, status (PENDING\|ACCEPTED\|REJECTED); unique on (LEAST,GREATEST) pair |
| `files` | uploader_id, bucket, object_key, original_name, mime_type, size_bytes, checksum, status (UPLOADING\|READY\|DELETED), scope |
| `attachments` | file_id, object_type (reuse ObjectType enum), object_id; index (object_type, object_id) |
| `role_requests` | user_id, requested_role, note, status (PENDING\|APPROVED\|REJECTED), reviewer_id, reviewed_at |
| `moderation_actions` | target_user_id, actor_id, action (BAN\|UNBAN\|ROLE_GRANT\|ROLE_REVOKE), reason, expires_at |
| `contribution_events` | user_id, event_type, weight, object_type, object_id, dedupe_key UNIQUE NULL (exact unvote compensation); index (user_id, created_at) |

**Exam engine**

| Table | Key columns |
|---|---|
| `exams` | creator_id, group_id NULL, title, description, mode (PRACTICE\|EXAM), status (DRAFT\|PUBLISHED\|ONGOING\|CLOSED\|ARCHIVED), open_at, close_at, duration_minutes, `settings JSONB` = {shuffle_questions, shuffle_options, max_attempts (default 1 in EXAM mode), grade_policy: BEST\|FIRST\|LAST (default BEST), reveal_policy: NEVER\|AFTER_SUBMIT\|AFTER_CLOSE\|IMMEDIATE, anti_cheat: {log_tab_switch, block_copy_paste, require_fullscreen, max_violations_warn, auto_flag (default true), max_violations_submit (auto-submit threshold, default 5, 0=off)}, ai_grading_enabled, code_scoring: ON_SUBMIT\|AT_END, code_first_submission_only, results_visible} |
| `exam_sections` | exam_id, title, description, order_index, settings JSONB |
| `questions` | creator_id, type (ONE_CHOICE\|MULTI_CHOICE\|SHORT_ANSWER\|LONG_ANSWER\|CODE), current_version_id, status, tags — question-bank head |
| `question_versions` | question_id, version_no, content, `config JSONB`, `answer JSONB`, explanation — **immutable; every edit inserts a new row**. Config per type: ONE/MULTI `{options[], scoring: ALL_OR_NOTHING\|PARTIAL}`; SHORT `{answer_kind: NUMBER\|TEXT, max_length, case_sensitive, trim, accepted[], numeric_tolerance}`; LONG `{max_length, rubric}`; CODE `{languages[judge0_ids], starter_code, test_cases[{input,expected,weight,hidden}], cpu_time_limit, memory_limit}`. `answer` always stripped from candidate DTOs |
| `exam_questions` | exam_id, section_id, question_id, question_version_id (pinned at publish), points, order_index, settings_override JSONB |
| `exam_members` | exam_id, user_id, role (CANDIDATE\|SCORER\|MANAGER), status; unique (exam_id,user_id); **SCORER/MANAGER can never create an attempt** |
| `exam_attempts` | exam_id, user_id, attempt_no, status (IN_PROGRESS\|SUBMITTED\|GRADING\|GRADED\|EXPIRED), started_at, submitted_at, deadline_at (personal deadline incl. extensions; NULL in practice), total_score, max_score, meta JSONB |
| `attempt_answers` | attempt_id, exam_question_id, question_version_id (**copied at attempt start — in-flight attempts keep their version**), answer JSONB, saved_at, auto_score, final_score, grading_status (NONE\|AUTO_DONE\|AI_PENDING\|AI_DONE\|MANUAL_PENDING\|MANUAL_DONE\|FAILED); unique (attempt_id, exam_question_id) — autosave = upsert |
| `code_submissions` | attempt_answer_id, language_id, source_code, judge0_tokens JSONB, status, passed_tests, total_tests, score, is_final |
| `grading_records` | attempt_answer_id, grader_type (AUTO\|AI\|MANUAL), grader_id, score, feedback, model_info JSONB, superseded BOOL — full audit; latest non-superseded wins |
| `exam_announcements` | exam_id, author_id, message |
| `exam_time_adjustments` | exam_id, attempt_id NULL (NULL = whole exam), delta_minutes / new_close_at, actor_id, reason |

### 3.3 Mongo collections

| Collection | Shape / indexes |
|---|---|
| `chat_conversations` | {type: DIRECT\|GROUP, directKey "lo:hi" unique (DIRECT), name, groupId (auto-created channel per learning Group), members[{userId, role, lastReadMessageId, lastReadAt, muted}], lastMessage{...}}; index members.userId + lastMessage.at desc |
| `chat_messages` | {conversationId, senderId, type TEXT\|FILE\|SYSTEM, content, attachments[fileId], replyToId, createdAt, editedAt, deletedAt}; index (conversationId, _id desc) — ObjectId = cursor; **no TTL** (retained indefinitely, soft-delete via deletedAt) |
| `notifications` | {userId, type (FRIEND_REQUEST, POST_COMMENT, COMMENT_REPLY, GROUP_INVITE, EXAM_INVITE, EXAM_GRADED, EXAM_ANNOUNCEMENT, ROLE_APPROVED, AI_GRADE_READY…), actorId, objectType, objectId, data, isRead}; indexes (userId,isRead), (userId,createdAt desc), TTL 180d |
| `proctor_events` | {examId, attemptId, userId, type (TAB_BLUR, TAB_FOCUS, VISIBILITY_HIDDEN, COPY, PASTE, FULLSCREEN_EXIT, DISCONNECT, RECONNECT, HEARTBEAT_MISS), at, severity (INFO\|WARN\|ALERT), meta}; index (examId, attemptId, at); **TTL 180d** |
| `ai_conversations` / `ai_messages` | per-user chatbot history + LangGraph checkpoints (owned by Python) |

### 3.4 Redis keys
`presence:{userId}` (TTL 60s) · `lb:global` / `lb:group:{id}` ZSET · `attempt_deadlines` ZSET (sweeper polls every 5s → auto-submit) · `unread:{userId}` HASH · `contrib:cap:{userId}:{type}:{yyyymmdd}` · `rl:*` (bucket4j-redis, Phase 4). Grading job queues live on **RabbitMQ**, not Redis.

---

## 4. Contribution Score Formula

Weights stored per-event in `contribution_events.weight` (tunable without breaking history):

| Event | Weight | Cap |
|---|---|---|
| POST_CREATED | +5 | 4/day |
| COMMENT_CREATED | +2 | 10/day |
| POST_UPVOTE_RECEIVED | +3 | self-votes excluded; unvote emits −3 via dedupe_key |
| COMMENT_UPVOTE_RECEIVED | +2 | — |
| DOWNVOTE_RECEIVED | −1 | per-object floor 0 |
| PRACTICE_COMPLETED | +3 | 3/day |
| EXAM_COMPLETED | +10 | once/exam |
| EXAM_SCORE_BONUS | +round(20 × score/max) | first attempt only |

`display_score = Σ weight × 0.5^(age_days/90)` (90-day half-life → leaderboard reflects current engagement); `lifetime_points = Σ weight` (all-time, on profile).

**Computation**: domain services publish Spring `ApplicationEvent`s → `ContributionListener` inserts `contribution_events` (caps via Redis INCR), instantly `ZINCRBY lb:global` + `users.contribution_score += weight`. Nightly `@Scheduled` job recomputes exact decayed scores from the event table and rebuilds ZSETs. **Source of truth = PG events; Redis = projection.**

---

## 5. Conventions (→ `docs/CONVENTIONS.md`)

**BE keep:** BaseResponse always-200 wrapper · `api/<area>/v1` paths · snake_case DTOs · `<Entity>Release`/`ReleaseCompact` via Releasable · Service/Query/Reader/Listener/ACL per aggregate (Query wraps MyBatis mappers) · AppContext · Long ids, epoch millis.

**BE change:**
- **JPA → MyBatis** per §2 ground rules; **Flyway owns the schema** (`V{n}__desc.sql`)
- Timestamps auto-filled by MyBatis interceptor (fixes bug 6)
- Bean Validation on new request DTOs (shape checks); Readers keep domain rules only
- Secrets → gitignored `.env` + placeholders; rotate committed JWT secret; ship `.env.example`
- springdoc-openapi, `/swagger-ui` dev-profile only
- Tests: JUnit 5 + Testcontainers (PG/Mongo/Redis)

**FE change:**
- **TanStack Query v5 for all server state**; Redux shrinks to UI state only (loading/modals)
- **Feature folders going forward**: `src/features/<feature>/{api,components,hooks,types}`; existing layer folders stay as shared/legacy
- **Auth reconcile: httpOnly cookies are the truth** — `withCredentials`, delete localStorage token + Bearer header + jwt-decode identity; add BE `GET /api/user/v1/me`; on `code==401` → refresh → retry once
- react-hook-form + zod · `@stomp/stompjs` · `@monaco-editor/react` · MUI v7 stays
- Naming: PascalCase components, `useXxx` hooks, `useFeedQuery`/`useSendMessageMutation`

**Git:** master repo + submodules per "Repository Structure" above. Conventional Commits; branches `feat/P1-4-friends-api`; task ids in commits.

---

## 6. Task Breakdown (each task ≈ one focused PR)

### Phase 0 — Foundation (codebase for all) — broken down to components

**P0-1 — Repo restructure (master + submodules)**
- Root: `git init`; root `.gitignore` (`.env`, logs, IDE dirs)
- FE: `git init` + initial commit; BE: commit current state as checkpoint (repo already exists)
- `git submodule add ./LearningHubBackend` · `git submodule add ./LearningHubFE` (relative URLs for local dev)
- Write `docs/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/DATABASE.md`, `docs/CONVENTIONS.md`, root `README.md`, `infra/.env.example`

**P0-2 — Secrets externalization**
- `application.properties`: literals → `${DB_URL}` `${DB_USER}` `${DB_PASSWORD}` `${JWT_SECRET}` `${RABBITMQ_HOST/USER/PASS}` `${SMTP_HOST/PORT/USER/PASS}` `${MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY}` `${AI_CALLBACK_SECRET}` `${OLLAMA_API_KEY}`
- `spring.config.import=optional:file:.env[.properties]`; `.env` gitignored; **rotate the committed JWT secret**

**P0-3 — docker-compose dev stack (`infra/`)**
- `docker-compose.yml`: postgres 16 (+volume), mongo 7 (+volume), redis 7, rabbitmq 4 (mount `enabled_plugins` = `[rabbitmq_management,rabbitmq_stomp].`), minio + one-shot `mc` bucket-init container, mailhog, ollama (+model volume); healthchecks on all
- `infra/judge0/docker-compose.yml` (stock CE) + `infra/README.md` run guide

**P0-4 — Flyway + Postgres schema**
- pom: remove `mysql-connector-j`; add `org.postgresql:postgresql`, `flyway-core`, `flyway-database-postgresql`
- `src/main/resources/db/migration/V1__init.sql`: all existing tables (drop `groups.members`; add `users.status/banned_until/contribution_score/lifetime_points`); delete `spring.jpa.hibernate.ddl-auto`

**P0-5 — MyBatis core setup**
- pom: remove `spring-boot-starter-data-jpa`, `spring-boot-starter-data-rest`; add `mybatis-spring-boot-starter` 3.x
- `configs/MyBatisConfig`: `@MapperScan("com.example.learninghubbackend.repositories")`
- properties: `mybatis.mapper-locations=classpath:mappers/**/*.xml` · `mybatis.configuration.map-underscore-to-camel-case=true` · `mybatis.type-handlers-package=…commons.typehandlers`
- `commons/typehandlers/JsonbMapTypeHandler extends BaseTypeHandler<Map<String,Object>>` (`@MappedTypes(Map.class)`, writes `PGobject` jsonb) · `JsonbLongListTypeHandler extends BaseTypeHandler<List<Long>>`
- `commons/mybatis/AuditInterceptor implements Interceptor` with `@Intercepts(@Signature(type=Executor.class, method="update", args={MappedStatement.class, Object.class}))` — fills `createdAt` on INSERT / `updatedAt` on UPDATE for `BaseModel` subclasses (**fixes bug 6**)
- `BaseModel`: drop `@MappedSuperclass` → plain POJO base

**P0-6 — Convert persistence: core aggregates (users, sessions, tokens, votes)**
- Per aggregate: `repositories/XxxMapper` (`@Mapper` interface) + `resources/mappers/xxx/XxxMapper.xml` (`<resultMap>`, `<insert useGeneratedKeys="true" keyProperty="id">`)
- Strip `@Entity/@Table/@Id/@GeneratedValue/@Column/@Convert/@Enumerated` from `User`, `Session`, `Token`, `Vote`
- `Token` UUID: `UuidUtil.v7()` set in service before insert; **delete** `commons/annotations/generatedUuidV7/*` and `commons/converters/*` (superseded by TypeHandlers)
- Rewire `UserQuery`, `SessionQuery`, token/vote query classes to mappers (services/ACLs unchanged in shape)

**P0-7 — Convert persistence: groups + posts**
- Same mapper+XML pattern for `Group`, `GroupMember`, `GroupInvitation`, `GroupRequest`, `Post`, `Comment`
- `group_members` = single source of truth: replace `Group.members` reads with `GroupMemberMapper.findAllByGroupId / existsByGroupIdAndUserId / countByGroupId`; capacity check `countByGroupId >= maxMember` in `GroupReader` (**fixes bug 5**); fix `GroupListener.onJoined` arg order (**bug 3**)

**P0-8 — Bug batch**
- `PostService.vote/unvote`: `ObjectType.COMMENT` → `ObjectType.POST` (**bug 1**)
- `CommentController.vote`: add `@RequestBody` (**bug 2**)
- `GroupRequestService.remove`: look up by `(groupId, userId)` instead of `getById(groupId)` (**bug 4**)

**P0-9 — Validation + OpenAPI**
- pom: `spring-boot-starter-validation`, `springdoc-openapi-starter-webmvc-ui`
- Request DTOs: `@NotBlank/@Size/@Email/@Min/@Max`; controllers take `@Valid @RequestBody`
- `GlobalExceptionHandler`: add `@ExceptionHandler(MethodArgumentNotValidException.class)` → `BaseResponse.error` with per-field messages
- `configs/OpenApiConfig` (`@OpenAPIDefinition`); swagger-ui gated to dev profile

**P0-10 — Mongo + Redis wiring**
- pom: `spring-boot-starter-data-mongodb`, `spring-boot-starter-data-redis`
- `configs/RedisConfig`: `RedisTemplate<String,Object>` with `GenericJackson2JsonRedisSerializer` + `StringRedisTemplate`
- `repositories/mongo/` package (`@EnableMongoRepositories`); `commons/models/BaseDocument` (`@Id String id`, epoch-millis `createdAt/updatedAt`)
- Health indicators exposed via Actuator

**P0-11 — File service (MinIO)**
- Flyway `V2__files.sql` (`files`, `attachments`); `models/StoredFile`, `models/Attachment` + `FileMapper`, `AttachmentMapper`
- `configs/MinioConfig` (`@Bean MinioClient`); `services/file/{FileService, FileQuery, FileReader, FileACL}`
- `controllers/FileController`: `POST /api/file/v1/upload` (`MultipartFile`, mime whitelist, `spring.servlet.multipart.max-file-size`) · `GET /api/file/v1/{id}` → presigned URL (`GetPresignedObjectUrlArgs`) · `DELETE /api/file/v1/{id}`

**P0-12 — `GET /api/user/v1/me`**
- `UserController.getMe()` via `AppContext.getUserId()` → `UserRelease` (FE cookie-auth prerequisite)

**P0-13 — STOMP + AMQP infra BE**
- pom: `spring-boot-starter-websocket`, `spring-boot-starter-amqp`
- `configs/WebSocketConfig implements WebSocketMessageBrokerConfigurer` (`@EnableWebSocketMessageBroker`): `addEndpoint("/ws").setAllowedOrigins(app.client.url)` · `enableStompBrokerRelay("/topic","/queue")` → RabbitMQ 61613 · `setApplicationDestinationPrefixes("/app")` · user destinations
- `configs/filters/WsAuthChannelInterceptor implements ChannelInterceptor` (`preSend`): CONNECT → authenticate from `access_token` cookie; SUBSCRIBE → destination ACL check
- `configs/RabbitConfig`: `@Bean DirectExchange grading`, queues `grading.code.jobs/dlq` + `grading.ai.jobs/dlq` with `x-dead-letter-exchange` args, `Jackson2JsonMessageConverter`, publisher confirms
- Smoke test: echo message to `/user/queue/notifications`

**P0-14 — FE auth reconcile + TanStack Query**
- `npm i @tanstack/react-query`; `QueryClientProvider` in `main.tsx`
- `axiosClient`: keep `withCredentials`; **delete** Bearer injection + localStorage `ACCESS_TOKEN`; response interceptor: `code==401` → `POST /auth/v1/refresh` (deduped promise) → retry once
- `useMeQuery()` (`['me']`); `vite.config.ts` → `server: { port: 5175 }` (**bug 9**)

**P0-15 — FE ProtectedRoutes + MainLayout wiring**
- Wire orphaned `ProtectedRoutes` + `MainLayout` into `routes.tsx`; unauthenticated → `/login`
- Lazy placeholder pages: `FeedPage, GroupsPage, ProfilePage, ExamsPage, ChatPage, AdminPage` (via existing `Loadable`)

**P0-16 — FE Register page**
- `npm i react-hook-form zod @hookform/resolvers`; `RegisterForm` with `zodResolver`; route `/register` → existing `POST /api/auth/v1/register`

**P0-17 — Forgot-password BE**
- pom: `spring-boot-starter-mail`; `services/mail/MailService` (`JavaMailSender`, `@Async`)
- `POST /api/auth/v1/forgot-password` {email} (always-200 to prevent user enumeration; Token `Action.FORGET_PASSWORD`, 30-min expiry) · `POST /api/auth/v1/reset-password` {token, new_password}; add to public matchers in `SecurityConfig`

**P0-18 — FE forgot/reset pages** (`/forgot-password`, `/reset-password?token=`)

**P0-19 — FE STOMP wrapper**
- `npm i @stomp/stompjs`; `src/lib/stompClient.ts` singleton (`brokerURL: ws://localhost:8080/ws`, exponential reconnect)
- `useSubscription(destination, onMessage)` hook (subscribe on mount, unsubscribe on cleanup)

**P0-20 — Actuator baseline**: expose `health,info,metrics`; restricted to ADMIN/OWNER

**P0-21 — CI per sub-repo**: `.github/workflows/ci.yml` — BE `mvn verify` · FE `npm ci && tsc -b && vite build` + eslint

**P0-22 — Test harness**
- pom (test scope): `spring-boot-testcontainers`, testcontainers `postgresql`/`mongodb`/`rabbitmq` modules + redis container
- `AbstractIntegrationTest` (`@SpringBootTest` + `@Testcontainers` + `@ServiceConnection`)
- First ITs: auth login/refresh flow, group join — safety net for the P0-6/7 conversions

### Phase 1 — Social

| # | Task |
|---|---|
| P1-1 | Profiles BE: `GET /api/user/v1/{id}/profile` · `PUT /api/user/v1/profile` {bio, school, birthday, links} · `PUT /api/user/v1/profile/avatar` & `/cover` {file_id} |
| P1-2 | FE profile page (view/edit, avatar/cover upload) |
| P1-3 | User search: `GET /api/user/v1/search?q=&cursor=` |
| P1-4 | Friends BE: `POST /api/friend/v1/request` {user_id} · `PUT /api/friend/v1/{id}/accept` · `PUT /api/friend/v1/{id}/reject` · `DELETE /api/friend/v1/{userId}` · `GET /api/friend/v1/list?cursor=` · `GET /api/friend/v1/requests?direction=in|out` |
| P1-5 | FE friends UI (search, requests inbox, list) |
| P1-6 | Feed endpoints: `GET /api/post/v1/feed?cursor=&limit=` (keyset on (score,id)) · `GET /api/group/v1/{id}/posts?cursor=` · `GET /api/user/v1/{id}/posts?cursor=` · `GET /api/post/v1/{id}` · `GET /api/post/v1/{id}/comments?cursor=` |
| P1-7 | FE feed: infinite scroll, composer, vote/comment, group feed tab |
| P1-8 | Post attachments: `file_ids[]` on create; render in feed |
| P1-9 | Chat conversations BE: `POST /api/chat/v1/conversations` {type, member_ids[], name?} (DIRECT dedupe by directKey) · `GET /api/chat/v1/conversations?cursor=`; auto-create GROUP conversation per learning Group (sync in GroupListener) |
| P1-10 | Chat messaging: STOMP `/app/chat.send` → persist → `/topic/conversation/{id}` + `/user/queue/chat`; `GET /api/chat/v1/conversations/{id}/messages?before=&limit=` · `PUT`/`DELETE /api/chat/v1/messages/{id}` |
| P1-11 | Read receipts + unread + typing: `PUT /api/chat/v1/conversations/{id}/read` {message_id}; Redis unread HASH; `/app/chat.typing` |
| P1-12 | FE chat UI (list w/ badges, thread, composer, typing/read) |
| P1-13 | Notifications BE: `NotificationService.emit()` from listeners; `GET /api/notification/v1/list?cursor=` · `PUT /api/notification/v1/read` {ids[]} · `PUT /api/notification/v1/read-all` · `GET /api/notification/v1/unread-count`; STOMP push |
| P1-14 | FE notifications (bell, dropdown, toasts, realtime) |
| P1-15 | Presence: WS connect/disconnect → Redis TTL; online badges; `GET /api/user/v1/presence?ids=` |
| P1-16 | Contribution v1 BE: events table, ApplicationEvents + ContributionListener, Redis caps, instant score updates |
| P1-17 | Leaderboards: nightly decay recompute; `GET /api/contribution/v1/leaderboard?scope=&group_id=&limit=` · `GET /api/contribution/v1/user/{id}` |
| P1-18 | FE leaderboard page + score on profile |

### Phase 2 — Exam Engine

| # | Task |
|---|---|
| P2-1 | Exam schema migration (all §3.2 exam tables + indexes) + MyBatis mappers skeleton |
| P2-2 | Question bank CRUD + versioning: `POST /api/question/v1/create` {type, content, config, answer, explanation, tags} · `PUT /api/question/v1/{id}` (new version row) · `GET /api/question/v1/{id}?version=` · `GET /api/question/v1/list?mine=&type=&tag=&cursor=` · `DELETE` = archive |
| P2-3 | Per-type config validators + answer-stripping sanitizer for candidate DTOs |
| P2-4 | Question attachments (images on versions) |
| P2-5 | Exam + sections CRUD: `POST /api/exam/v1/create` {title, group_id?, mode, settings} · `PUT`/`DELETE /api/exam/v1/{id}` · `GET /api/exam/v1/{id}` · `GET /api/exam/v1/list?filter=&status=&cursor=` · sections CRUD + reorder |
| P2-6 | Attach questions: `POST /api/exam/v1/sections/{id}/questions` {question_id, points, order_index} (pins version) · update/remove/reorder |
| P2-7 | Publish + schedule: `PUT /api/exam/v1/{id}/publish` · `PUT /api/exam/v1/{id}/schedule` {open_at, close_at, duration_minutes}; status state machine |
| P2-8 | Exam members: `POST /api/exam/v1/{id}/members` {user_ids[], role} · `DELETE .../members/{userId}` · `GET .../members`; group exams auto-enroll; SCORER/MANAGER blocked from attempts |
| P2-9 | Attempt start/resume: `POST /api/exam/v1/{id}/attempts` (eligibility, snapshot version ids, deadline_at, Redis ZSET) · `GET /api/exam/v1/attempts/{id}` (resume + server time) |
| P2-10 | Autosave: `PUT /api/exam/v1/attempts/{id}/answers` {exam_question_id, answer} (upsert, rejects after deadline) · `GET /api/time/v1/now` |
| P2-11 | Deadline sweeper: poll ZSET → auto-submit → broadcast force-submit |
| P2-12 | Submit + auto-grading: `POST /api/exam/v1/attempts/{id}/submit`; graders ONE_CHOICE, MULTI_CHOICE (all-or-nothing / partial correctSelected/totalCorrect), SHORT_ANSWER (trim/case/tolerance); long → MANUAL_PENDING (AI from P3) |
| P2-13 | Practice mode: no deadline; `POST /api/exam/v1/attempts/{id}/reveal` {exam_question_id} per reveal_policy |
| P2-14 | Announcements: `POST /api/exam/v1/{id}/announcements` {message} → persist + broadcast · `GET` list |
| P2-15 | Time control: `PUT /api/exam/v1/{id}/time` {delta_minutes | new_close_at, attempt_id?} → deadlines + ZSET + broadcast; audit table |
| P2-16 | Live progress: `/app/exam.heartbeat` → `/topic/exam/{id}/monitor`; snapshot `GET /api/exam/v1/{id}/progress` |
| P2-17 | Anti-cheat logging + enforcement: `POST /api/exam/v1/attempts/{id}/events` {events[]} (batched) → Mongo + severity rules + monitor relay · `GET /api/exam/v1/{id}/events?attempt_id=&cursor=`; **enforcement decided ON**: warn candidate at `max_violations_warn`, auto-flag attempt, force-submit at `max_violations_submit` (broadcast + attempt marked FLAGGED for review) |
| P2-18 | Code judging queue: `grading.code.jobs`/`dlq` RabbitMQ queues + BE `CodeJudgeWorker` `@RabbitListener` pool (Judge0 batch submit + token polling, nack→retry→DLQ), `GET /api/exam/v1/code/languages`, base64, limits from config |
| P2-19 | Code submissions: `POST /api/exam/v1/attempts/{id}/code` {exam_question_id, language_id, source_code} (first-submission-only enforcement) → persist QUEUED + AMQP publish, return immediately · `GET /api/exam/v1/code-submissions/{id}` (status/results, hidden tests masked) + live status push; ON_SUBMIT vs AT_END scoring |
| P2-20 | Manual grading: `GET /api/exam/v1/{id}/grading/queue?cursor=` · `POST /api/exam/v1/grading/{attemptAnswerId}` {score, feedback} (SCORER/MANAGER); finalize when queue empty |
| P2-21 | Results/review: `GET /api/exam/v1/attempts/{id}/result` · `GET /api/exam/v1/attempts/{id}/review` (gated by reveal_policy) · `GET /api/exam/v1/{id}/results` (manager table) |
| P2-22 | FE question bank UI (per-type editors incl. test cases) |
| P2-23 | FE exam builder (sections board, attach/reorder, publish/schedule) |
| P2-24 | FE exam list/lobby + member management |
| P2-25 | FE taking shell: server-synced timer, navigation, autosave indicator; practice vs exam variants |
| P2-26 | FE Monaco code question (language picker, run/submit, results panel) |
| P2-27 | FE anti-cheat instrumentation: visibilitychange/blur/copy/paste/fullscreen → batched events; block + warn per config |
| P2-28 | FE teacher live monitor (progress grid, violation feed, announcements, time extension) |
| P2-29 | FE grading UI for scorers |
| P2-30 | FE results/review pages (student + manager) |

### Phase 3 — AI

| # | Task |
|---|---|
| P3-1 | `ai-server/` scaffold (own git repo + submodule): FastAPI, pydantic-settings, `GET /health` · `GET /models`, Ollama Cloud sign-in check (`OLLAMA_API_KEY`), Dockerfile + compose; model configurable via env — default an Ollama **cloud model** (e.g. `gpt-oss:120b-cloud` / `deepseek-v3.1:671b-cloud`), small local model documented as offline fallback |
| P3-2 | Grading chain: LangChain structured output (rubric+question+reference+answer → {score, max_score, feedback, confidence}), prompt versioning, injection guards (answer fenced as data), golden eval set |
| P3-3 | Job plumbing: BE AMQP publisher (persistent + publisher confirms); Python aio-pika consumer (prefetch 1) + retry/backoff → DLQ; BE `POST /internal/ai/v1/grading-callback` (HMAC, idempotent) |
| P3-4 | Dispatch integration: practice → SHORT/LONG always AI; exam → iff `ai_grading_enabled`; grading_records(AI), totals, AI_GRADE_READY notification |
| P3-5 | Unified queue ops (code + AI): `GET /api/admin/v1/grading/jobs?queue=code\|ai&status=` (depths/DLQ via RabbitMQ management API) · `POST /api/admin/v1/grading/jobs/requeue` {queue, job_ids[]}; queue-depth gauges |
| P3-6 | Teacher override: manual grade supersedes AI record; `POST /api/exam/v1/attempts/{id}/regrade` {exam_question_id} |
| P3-7 | Chatbot agent: LangGraph study assistant, Mongo checkpoints, per-user isolation |
| P3-8 | BE chat proxy: `POST /api/ai/v1/chat` {conversation_id?, message} → SSE · `GET /api/ai/v1/conversations` · `GET .../{id}/messages?cursor=` · `DELETE .../{id}`; per-user rate limit |
| P3-9 | FE chatbot UI (streaming panel, history sidebar) |
| P3-10 | AI status: `GET /api/admin/v1/ai/status` (health, models, queue depth, last callback age) |
| P3-11 | Hardening: token/time limits, max answer length, timeout → FAILED → manual fallback verified e2e |

### Phase 4 — Admin & Polish

| # | Task |
|---|---|
| P4-1 | Admin users: `GET /api/admin/v1/users?q=&role=&status=&cursor=` · `GET /api/admin/v1/users/{id}` (sessions, moderation history) |
| P4-2 | Ban/unban: `PUT /api/admin/v1/users/{id}/ban` {reason, until?} (revokes sessions; JwtFilter rejects BANNED) · `/unban`; moderation log |
| P4-3 | Admin create account: `POST /api/admin/v1/users` {username, email, role, temp_password} + forced first-login reset |
| P4-4 | Teacher role requests: `POST /api/user/v1/role-request` {role, note} · `GET /api/admin/v1/role-requests?status=` · `PUT .../{id}/approve` / `/reject` {note} + notification |
| P4-5 | Metrics: custom counters (DAU, posts/day, attempts/day, WS connections) + `GET /api/admin/v1/metrics` |
| P4-6 | Composite status: `GET /api/admin/v1/status` (PG/Mongo/Redis/MinIO/Judge0/AI health + latency) |
| P4-7 | FE admin dashboard (users, ban, create, role-request queue) |
| P4-8 | FE status/metrics page |
| P4-9 | Security pass: bucket4j→Redis, cookie flags/SameSite, CSP headers, dependency audit, prod CORS |
| P4-10 | Test push: exam lifecycle + grading + chat integration suites; FE vitest smoke |
| P4-11 | Performance: index review, slow-query logging, feed cache option |
| P4-12 | Ops polish: seed fixtures, backup scripts (pg_dump/mongodump), runbook |

---

## 7. Verification

- **Phase 0**: `docker compose up` brings the full stack healthy; BE boots on PG with Flyway `V1` and all MyBatis mappers pass integration tests; existing FE login works via cookies-only path; Swagger UI lists all endpoints; Testcontainers suite green in CI; register/forgot-password work end-to-end via MailHog; master repo shows BE/FE as submodules.
- **Per feature**: integration test (Testcontainers) + drive the flow in the running app (two browser sessions for chat/friends; teacher+student sessions for exams; kill the AI container mid-grading to verify the DLQ → manual fallback path).
- **Exam engine**: publish → edit question → verify in-flight attempt still renders/grades the pinned version; let a timer expire → sweeper auto-submits; extend time mid-exam → candidate timer updates live.

## 8. Jira Backlog Export

Deliverable: **`docs/jira-backlog.csv`** in the master repo — importable via Jira's CSV import (External System Import). One row per issue.

**Columns:** `Summary, Issue Type, Epic Name, Epic Link, Description, Labels, Priority`
- Epic rows: `Issue Type=Epic` + `Epic Name` filled.
- Task rows: `Issue Type=Task` + `Epic Link` = the epic's name (company-managed projects; for team-managed, map the column to `Parent` during import).
- `Summary` keeps the plan's task id: e.g. `[P0-5] MyBatis core setup`. `Labels` = `phase-0…phase-4` + `backend`/`frontend`/`ai`/`infra`. `Description` carries the full task detail incl. HTTP method + path for API tasks.

**Epics (10):**

| Epic | Contains |
|---|---|
| LH Foundation & Codebase | P0-1 … P0-22 |
| LH Profiles & Friends | P1-1 … P1-5 |
| LH Feed & Posts | P1-6 … P1-8 |
| LH Chat & Notifications | P1-9 … P1-15 |
| LH Contribution & Leaderboard | P1-16 … P1-18 |
| LH Question Bank & Exam Authoring | P2-1 … P2-8, P2-22 … P2-24 |
| LH Exam Taking & Anti-cheat | P2-9 … P2-17, P2-25, P2-27, P2-28 |
| LH Grading & Code Judge | P2-18 … P2-21, P2-26, P2-29, P2-30 |
| LH AI Services | P3-1 … P3-11 |
| LH Admin & Ops | P4-1 … P4-12 |

Priorities: Phase 0 tasks = High; P1/P2 = Medium; P3/P4 = Low (adjustable in Jira after import).

## 9. Decided Defaults & Remaining Risks

**Decided (previously open):**
- **Queues + realtime broker = RabbitMQ** — grading job queues (code + AI) on durable AMQP queues with DLX, and STOMP broker relay for WebSocket. Resolves the simple-broker single-node limitation.
- **Multiple-attempt policy** — per-exam `settings.grade_policy: BEST|FIRST|LAST`, **default BEST** (student-friendly, standard LMS default); EXAM mode defaults `max_attempts=1` so it rarely matters there; contribution `EXAM_SCORE_BONUS` always counts the **first** attempt only (anti-farming).
- **Retention** — `proctor_events` **180 days** (Mongo TTL index; long enough for grade disputes), `notifications` 180 days, **chat retained indefinitely** (soft-delete via `deletedAt`; history is product value — revisit only if storage grows), AI conversations kept until the user deletes them.
- **Prod SMTP** — **Brevo free tier** (300 emails/day, plain SMTP relay): swapping from dev MailHog is a `.env`-only change since we use spring-boot-starter-mail. Fallback for pure-personal use: Gmail app-password SMTP.
- **JPA → MyBatis rewrite: accepted** — the P0-5..7 conversion cost is acknowledged and taken deliberately; done together with the PG switch (one persistence rewrite, not two) with the P0-22 test harness as the safety net.
- **AI model failure handling** — retries are **configurable** (`AI_MAX_RETRIES`, default 3, exponential backoff); when exhausted (model disconnected, Ollama Cloud unreachable, timeout) the answer goes to `FAILED` → manual grading and the **teacher/exam manager gets a push notification**; admin can requeue from the DLQ.
- **Anti-cheat enforcement: ON** — violations auto-flag the attempt; candidate is warned at `max_violations_warn` and the attempt is **force-submitted at `max_violations_submit`** (default 5; per-exam configurable, 0 disables). Flagged attempts are highlighted for teacher review. (Browsers still can't block second devices — logging + enforcement is best-effort by design.)

**Remaining risks:**
1. **Prod cookie+WS cross-origin layout** (same origin vs subdomains, SameSite) undecided.
2. **Judge0 is heavy** (own PG/Redis/workers) — may start it only when working on code questions in dev.
3. **Submodules add friction** (two-step commits master↔sub) — accepted trade-off for independent repos per the owner's preference.
4. **RabbitMQ is one more stateful service** (STOMP plugin config, DLX topology) — accepted for durable jobs + multi-node-ready realtime.
5. **Ollama Cloud privacy/quota** — student answers leave the machine and quota depends on ollama.com; acceptable for a personal project. Exact cloud model choice still open.
