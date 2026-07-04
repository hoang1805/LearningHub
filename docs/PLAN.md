# LearningHub — Master Development Plan

Companion docs: [ARCHITECTURE.md](ARCHITECTURE.md) (system design, realtime, judging queues) · [DATABASE.md](DATABASE.md) (schemas, data placement, contribution formula) · [CONVENTIONS.md](CONVENTIONS.md) (code/API/git rules).

## Context

LearningHub is a learning platform for students, teachers, and admins: a social core (profiles, friends, chat, groups, posts, feeds, contribution score) plus an exam engine (practice/exam modes, sections, 5 question types incl. code with Judge0, anti-cheat tracking, live monitoring) plus AI services (grading of short/long answers, study chatbot) and admin tooling.

**Starting point:**
- `LearningHubBackend/` — Spring Boot 3.5.5, Java 21, MySQL + Spring Data JPA (both being replaced), JWT-in-cookies auth with single-active-session fingerprinting, Bucket4j throttling. Implemented: auth, users, groups (members/invitations/requests/token-join), posts/comments/votes.
- `LearningHubFE/` — React 19 + Vite 7 + TS strict, MUI v7 (themed) + Tailwind v4, Redux Toolkit, axios with refresh interceptor. Only the login flow exists.

**Locked decisions:** PostgreSQL + MongoDB + Redis · **MyBatis** (not JPA) · MUI v7 · Judge0 CE self-hosted · **RabbitMQ** for grading queues + STOMP broker relay · Python AI server (FastAPI + LangChain + LangGraph) on **Ollama Cloud** models · master repo + sub-repos (submodules) · build order **Foundation → Social → Exams → AI → Admin**.

**Known bugs fixed during Foundation:**
1. `PostService.vote/unvote` uses `ObjectType.COMMENT` instead of `POST`
2. `CommentController.vote` missing `@RequestBody`
3. Group membership stored redundantly (`Group.members` JSON + `GroupMember` rows), inconsistent arg order in `GroupListener.onJoined`
4. `GroupRequestService.remove(groupId, userId)` treats groupId as a request id
5. `Group.addMember` capacity guard inverted
6. `updatedAt` never advances on edits
7. Secrets committed in `application.properties`
8. FE stores JWT in localStorage while BE issues httpOnly cookies (two divergent auth paths)
9. `vite.config.ts` missing `server.port: 5175` (BE CORS only allows 5175)

---

## Phase 0 — Foundation (codebase for all)

**P0-1 — Repo restructure (master + submodules)**
- Root: `git init`; root `.gitignore` (`.env`, logs, IDE dirs)
- FE: `git init` + initial commit; BE: commit current state as checkpoint (repo already exists)
- `git submodule add ./LearningHubBackend` · `git submodule add ./LearningHubFE` (relative URLs for local dev)
- Write `docs/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/DATABASE.md`, `docs/CONVENTIONS.md`, root `README.md`, `infra/.env.example`

**P0-2 — Secrets externalization**
- `application.properties`: literals → `${DB_URL}` `${DB_USER}` `${DB_PASSWORD}` `${JWT_SECRET}` `${RABBITMQ_HOST/USER/PASS}` `${SMTP_HOST/PORT/USER/PASS}` `${MINIO_ENDPOINT/ACCESS_KEY/SECRET_KEY}` `${AI_CALLBACK_SECRET}` `${OLLAMA_API_KEY}`
- `spring.config.import=optional:file:.env[.properties]`; `.env` gitignored; **rotate the committed JWT secret**

**P0-3 — docker-compose dev stack (`infra/`)**
- `docker-compose.yml`: postgres 16 (+volume), mongo 7 (+volume), redis 7, rabbitmq 4 (mount `enabled_plugins` = `[rabbitmq_management,rabbitmq_stomp].`), minio + one-shot `mc` bucket-init container, mailhog; healthchecks on all. Ollama = existing WSL install (localhost:11434), not containerized
- `infra/judge0/docker-compose.yml` (stock CE) + `infra/README.md` run guide

**P0-4 — Flyway + Postgres schema**
- pom: remove `mysql-connector-j`; add `org.postgresql:postgresql`, `flyway-core`, `flyway-database-postgresql`
- `db/migration/V1__init.sql`: all existing tables (drop `groups.members`; add `users.status/banned_until/contribution_score/lifetime_points`); delete `spring.jpa.hibernate.ddl-auto`

**P0-5 — MyBatis core setup**
- pom: remove `spring-boot-starter-data-jpa`, `spring-boot-starter-data-rest`; add `mybatis-spring-boot-starter` 3.x
- `configs/MyBatisConfig`: `@MapperScan("com.example.learninghubbackend.repositories")`
- properties: `mybatis.mapper-locations=classpath:mappers/**/*.xml` · `map-underscore-to-camel-case=true` · `type-handlers-package`
- `commons/typehandlers/JsonbMapTypeHandler extends BaseTypeHandler<Map<String,Object>>` (`@MappedTypes(Map.class)`, writes `PGobject` jsonb) · `JsonbLongListTypeHandler extends BaseTypeHandler<List<Long>>`
- `commons/mybatis/AuditInterceptor implements Interceptor` with `@Intercepts(@Signature(type=Executor.class, method="update", args={MappedStatement.class, Object.class}))` — fills `createdAt` on INSERT / `updatedAt` on UPDATE (**fixes bug 6**)
- `BaseModel`: drop `@MappedSuperclass` → plain POJO base

**P0-6 — Convert persistence: core aggregates (users, sessions, tokens, votes)**
- Per aggregate: `repositories/XxxMapper` (`@Mapper`) + `resources/mappers/xxx/XxxMapper.xml` (`<resultMap>`, `<insert useGeneratedKeys="true" keyProperty="id">`)
- Strip `@Entity/@Table/@Id/@GeneratedValue/@Column/@Convert/@Enumerated` from `User`, `Session`, `Token`, `Vote`
- `Token` UUID via `UuidUtil.v7()` in service; **delete** `commons/annotations/generatedUuidV7/*` and `commons/converters/*`
- Rewire `UserQuery`, `SessionQuery`, token/vote query classes to mappers (services/ACLs unchanged in shape)

**P0-7 — Convert persistence: groups + posts**
- Same mapper+XML pattern for `Group`, `GroupMember`, `GroupInvitation`, `GroupRequest`, `Post`, `Comment`
- `group_members` = single source of truth: replace `Group.members` reads with `GroupMemberMapper.findAllByGroupId / existsByGroupIdAndUserId / countByGroupId`; capacity check `countByGroupId >= maxMember` in `GroupReader` (**fixes bug 5**); fix `GroupListener.onJoined` arg order (**bug 3**)

**P0-8 — Bug batch**
- `PostService.vote/unvote`: `ObjectType.COMMENT` → `ObjectType.POST` (**bug 1**) · `CommentController.vote`: add `@RequestBody` (**bug 2**) · `GroupRequestService.remove`: look up by `(groupId, userId)` (**bug 4**)

**P0-9 — Validation + OpenAPI**
- pom: `spring-boot-starter-validation`, `springdoc-openapi-starter-webmvc-ui`
- DTOs: `@NotBlank/@Size/@Email/@Min/@Max`; controllers `@Valid @RequestBody`
- `GlobalExceptionHandler`: `@ExceptionHandler(MethodArgumentNotValidException.class)` → `BaseResponse.error` with per-field messages
- `configs/OpenApiConfig` (`@OpenAPIDefinition`); swagger-ui dev profile only

**P0-10 — Mongo + Redis wiring**
- pom: `spring-boot-starter-data-mongodb`, `spring-boot-starter-data-redis`
- `configs/RedisConfig`: `RedisTemplate<String,Object>` (`GenericJackson2JsonRedisSerializer`) + `StringRedisTemplate`
- `repositories/mongo/` (`@EnableMongoRepositories`); `commons/models/BaseDocument` (`@Id String id`, epoch-millis timestamps); health indicators

**P0-11 — File service (MinIO)**
- Flyway `V2__files.sql` (`files`, `attachments`); `models/StoredFile`, `models/Attachment` + mappers
- `configs/MinioConfig` (`@Bean MinioClient`); `services/file/{FileService, FileQuery, FileReader, FileACL}`
- `POST /api/file/v1/upload` (`MultipartFile`, mime whitelist, size limit) · `GET /api/file/v1/{id}` → presigned URL · `DELETE /api/file/v1/{id}`

**P0-12 — `GET /api/user/v1/me`** — `UserController.getMe()` via `AppContext.getUserId()` → `UserRelease` (FE cookie-auth prerequisite)

**P0-13 — STOMP + AMQP infra BE**
- pom: `spring-boot-starter-websocket`, `spring-boot-starter-amqp`
- `configs/WebSocketConfig implements WebSocketMessageBrokerConfigurer` (`@EnableWebSocketMessageBroker`): `addEndpoint("/ws").setAllowedOrigins(app.client.url)` · `enableStompBrokerRelay("/topic","/queue")` → RabbitMQ 61613 · `setApplicationDestinationPrefixes("/app")`
- `configs/filters/WsAuthChannelInterceptor implements ChannelInterceptor` (`preSend`): CONNECT → auth from `access_token` cookie; SUBSCRIBE → destination ACL
- `configs/RabbitConfig`: `@Bean DirectExchange grading`, queues `grading.code.jobs/dlq` + `grading.ai.jobs/dlq` with `x-dead-letter-exchange` args, `Jackson2JsonMessageConverter`, publisher confirms
- Smoke test: echo to `/user/queue/notifications`

**P0-14 — FE auth reconcile + TanStack Query**
- `npm i @tanstack/react-query`; `QueryClientProvider` in `main.tsx`
- `axiosClient`: keep `withCredentials`; **delete** Bearer injection + localStorage `ACCESS_TOKEN`; response interceptor: `code==401` → refresh (deduped) → retry once
- `useMeQuery()`; `vite.config.ts` → `server: { port: 5175 }` (**bug 9**)

**P0-15 — FE ProtectedRoutes + MainLayout wiring** — wire orphaned components into `routes.tsx`; lazy placeholder pages: `FeedPage, GroupsPage, ProfilePage, ExamsPage, ChatPage, AdminPage`

**P0-16 — FE Register page** — `npm i react-hook-form zod @hookform/resolvers`; `RegisterForm` (zodResolver); route `/register` → existing `POST /api/auth/v1/register`

**P0-17 — Forgot-password BE**
- pom: `spring-boot-starter-mail`; `services/mail/MailService` (`JavaMailSender`, `@Async`)
- `POST /api/auth/v1/forgot-password` {email} (always-200 to prevent enumeration; Token `Action.FORGET_PASSWORD`, 30-min expiry) · `POST /api/auth/v1/reset-password` {token, new_password}; add to public matchers

**P0-18 — FE forgot/reset pages** (`/forgot-password`, `/reset-password?token=`)

**P0-19 — FE STOMP wrapper** — `npm i @stomp/stompjs`; `src/lib/stompClient.ts` singleton (exponential reconnect); `useSubscription(destination, onMessage)` hook

**P0-20 — Actuator baseline** — expose `health,info,metrics`; restricted to ADMIN/OWNER

**P0-21 — CI per sub-repo** — `.github/workflows/ci.yml`: BE `mvn verify` · FE `npm ci && tsc -b && vite build` + eslint

**P0-22 — Test harness** — `spring-boot-testcontainers` + PG/Mongo/RabbitMQ/redis containers; `AbstractIntegrationTest` (`@SpringBootTest` + `@Testcontainers` + `@ServiceConnection`); first ITs: auth login/refresh, group join

## Phase 1 — Social

| # | Task |
|---|---|
| P1-1 | Profiles BE: `GET /api/user/v1/{id}/profile` · `PUT /api/user/v1/profile` {bio, school, birthday, links} · `PUT /api/user/v1/profile/avatar` & `/cover` {file_id} |
| P1-2 | FE profile page (view/edit, avatar/cover upload) |
| P1-3 | User search: `GET /api/user/v1/search?q=&cursor=` |
| P1-4 | Friends BE: `POST /api/friend/v1/request` {user_id} · `PUT /api/friend/v1/{id}/accept` · `PUT /api/friend/v1/{id}/reject` · `DELETE /api/friend/v1/{userId}` · `GET /api/friend/v1/list?cursor=` · `GET /api/friend/v1/requests?direction=in\|out` |
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

## Phase 2 — Exam Engine

| # | Task |
|---|---|
| P2-1 | Exam schema migration (all exam tables + indexes, see DATABASE.md) + MyBatis mappers skeleton |
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
| P2-12 | Submit + auto-grading: `POST /api/exam/v1/attempts/{id}/submit`; graders ONE_CHOICE, MULTI_CHOICE (all-or-nothing / partial), SHORT_ANSWER (trim/case/tolerance); long → MANUAL_PENDING (AI from P3) |
| P2-13 | Practice mode: no deadline; `POST /api/exam/v1/attempts/{id}/reveal` {exam_question_id} per reveal_policy |
| P2-14 | Announcements: `POST /api/exam/v1/{id}/announcements` {message} → persist + broadcast · `GET` list |
| P2-15 | Time control: `PUT /api/exam/v1/{id}/time` {delta_minutes \| new_close_at, attempt_id?} → deadlines + ZSET + broadcast; audit table |
| P2-16 | Live progress: `/app/exam.heartbeat` → `/topic/exam/{id}/monitor`; snapshot `GET /api/exam/v1/{id}/progress` |
| P2-17 | Anti-cheat logging + enforcement: `POST /api/exam/v1/attempts/{id}/events` {events[]} (batched) → Mongo + severity rules + monitor relay · `GET /api/exam/v1/{id}/events?attempt_id=&cursor=`; **enforcement ON**: warn at `max_violations_warn`, auto-flag, force-submit at `max_violations_submit` |
| P2-18 | Code judging queue: `grading.code.jobs`/`dlq` RabbitMQ queues + BE `CodeJudgeWorker` `@RabbitListener` pool (Judge0 batch submit + token polling, nack→retry→DLQ), `GET /api/exam/v1/code/languages`, base64, limits from config |
| P2-19 | Code submissions: `POST /api/exam/v1/attempts/{id}/code` {exam_question_id, language_id, source_code} (first-submission-only enforcement) → persist QUEUED + AMQP publish, return immediately · `GET /api/exam/v1/code-submissions/{id}` (hidden tests masked) + live status push; ON_SUBMIT vs AT_END scoring |
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

## Phase 3 — AI

| # | Task |
|---|---|
| P3-1 | `ai-server/` scaffold (own git repo + submodule): FastAPI, pydantic-settings, `GET /health` · `GET /models`, Ollama Cloud sign-in check (`OLLAMA_API_KEY`), Dockerfile + compose; model via env — default an Ollama **cloud model** (e.g. `gpt-oss:120b-cloud`), small local model as offline fallback |
| P3-2 | Grading chain: LangChain structured output (rubric+question+reference+answer → {score, max_score, feedback, confidence}), prompt versioning, injection guards, golden eval set |
| P3-3 | Job plumbing: BE AMQP publisher (persistent + confirms); Python aio-pika consumer (prefetch 1) + retry/backoff → DLQ; BE `POST /internal/ai/v1/grading-callback` (HMAC, idempotent) |
| P3-4 | Dispatch integration: practice → SHORT/LONG always AI; exam → iff `ai_grading_enabled`; grading_records(AI), totals, AI_GRADE_READY notification |
| P3-5 | Unified queue ops (code + AI): `GET /api/admin/v1/grading/jobs?queue=code\|ai&status=` (via RabbitMQ management API) · `POST /api/admin/v1/grading/jobs/requeue` {queue, job_ids[]}; queue-depth gauges |
| P3-6 | Teacher override: manual grade supersedes AI record; `POST /api/exam/v1/attempts/{id}/regrade` {exam_question_id} |
| P3-7 | Chatbot agent: LangGraph study assistant, Mongo checkpoints, per-user isolation |
| P3-8 | BE chat proxy: `POST /api/ai/v1/chat` {conversation_id?, message} → SSE · `GET /api/ai/v1/conversations` · `GET .../{id}/messages?cursor=` · `DELETE .../{id}`; per-user rate limit |
| P3-9 | FE chatbot UI (streaming panel, history sidebar) |
| P3-10 | AI status: `GET /api/admin/v1/ai/status` (health, models, queue depth, last callback age) |
| P3-11 | Hardening: token/time limits, max answer length, timeout → FAILED → manual fallback verified e2e |

## Phase 4 — Admin & Polish

| # | Task |
|---|---|
| P4-1 | Admin users: `GET /api/admin/v1/users?q=&role=&status=&cursor=` · `GET /api/admin/v1/users/{id}` (sessions, moderation history) |
| P4-2 | Ban/unban: `PUT /api/admin/v1/users/{id}/ban` {reason, until?} (revokes sessions; JwtFilter rejects BANNED) · `/unban`; moderation log |
| P4-3 | Admin create account: `POST /api/admin/v1/users` {username, email, role, temp_password} + forced first-login reset |
| P4-4 | Teacher role requests: `POST /api/user/v1/role-request` {role, note} · `GET /api/admin/v1/role-requests?status=` · `PUT .../{id}/approve` / `/reject` {note} + notification |
| P4-5 | Metrics: custom counters (DAU, posts/day, attempts/day, WS connections) + `GET /api/admin/v1/metrics` |
| P4-6 | Composite status: `GET /api/admin/v1/status` (PG/Mongo/Redis/RabbitMQ/MinIO/Judge0/AI health + latency) |
| P4-7 | FE admin dashboard (users, ban, create, role-request queue) |
| P4-8 | FE status/metrics page |
| P4-9 | Security pass: bucket4j→Redis, cookie flags/SameSite, CSP headers, dependency audit, prod CORS |
| P4-10 | Test push: exam lifecycle + grading + chat integration suites; FE vitest smoke |
| P4-11 | Performance: index review, slow-query logging, feed cache option |
| P4-12 | Ops polish: seed fixtures, backup scripts (pg_dump/mongodump), runbook |

---

## Jira backlog export

`docs/jira-backlog.csv` — importable via Jira CSV import (External System Import). Columns: `Summary, Issue Type, Epic Name, Epic Link, Description, Labels, Priority`. Task summaries keep plan ids (`[P0-5] MyBatis core setup`). For team-managed projects map `Epic Link` → `Parent` during import.

**Epics (10):** Foundation & Codebase (P0-*) · Profiles & Friends (P1-1..5) · Feed & Posts (P1-6..8) · Chat & Notifications (P1-9..15) · Contribution & Leaderboard (P1-16..18) · Question Bank & Exam Authoring (P2-1..8, 22..24) · Exam Taking & Anti-cheat (P2-9..17, 25, 27, 28) · Grading & Code Judge (P2-18..21, 26, 29, 30) · AI Services (P3-*) · Admin & Ops (P4-*).

## Verification

- **Phase 0**: `docker compose up` brings the full stack healthy; BE boots on PG with Flyway `V1` and all MyBatis mappers pass integration tests; FE login works via cookies-only path; Swagger UI lists all endpoints; Testcontainers suite green in CI; register/forgot-password work end-to-end via MailHog; master repo shows BE/FE as submodules.
- **Per feature**: integration test (Testcontainers) + drive the flow in the running app (two browser sessions for chat/friends; teacher+student sessions for exams; kill the AI container mid-grading to verify DLQ → manual fallback).
- **Exam engine**: publish → edit question → in-flight attempt still renders/grades the pinned version; timer expiry → sweeper auto-submits; time extension mid-exam → candidate timer updates live; violation threshold → auto-flag + force-submit.

## Decided defaults

- **Queues + realtime broker = RabbitMQ** — durable AMQP grading queues with DLX + STOMP broker relay (no single-node simple-broker limitation).
- **Multiple-attempt policy** — per-exam `settings.grade_policy: BEST|FIRST|LAST`, default **BEST**; EXAM mode defaults `max_attempts=1`; contribution `EXAM_SCORE_BONUS` counts the **first** attempt only.
- **Retention** — proctor_events **180d** (Mongo TTL), notifications 180d, chat **indefinite** (soft-delete), AI conversations until user deletes.
- **Prod SMTP** — **Brevo free tier** (300/day; .env-only swap from MailHog). Fallback: Gmail app-password.
- **JPA → MyBatis rewrite: accepted** — done together with the PG switch (one persistence rewrite), P0-22 test harness as safety net.
- **AI failure handling** — retries configurable (`AI_MAX_RETRIES`, default 3, backoff); on exhaustion → `FAILED` → manual grading + **teacher push notification**; DLQ requeue by admin.
- **Anti-cheat enforcement: ON** — auto-flag violations; warn at `max_violations_warn`, force-submit at `max_violations_submit` (default 5, 0=off); flagged attempts highlighted for review.

## Remaining risks

1. **Prod cookie+WS cross-origin layout** (same origin vs subdomains, SameSite) undecided.
2. **Judge0 is heavy** (own PG/Redis/workers) — start it only when working on code questions in dev.
3. **Submodules add friction** (two-step commits master↔sub) — accepted for independent repos.
4. **RabbitMQ is one more stateful service** — accepted for durable jobs + multi-node-ready realtime.
5. **Ollama Cloud privacy/quota** — student answers leave the machine; quota depends on ollama.com. Exact cloud model choice still open.
