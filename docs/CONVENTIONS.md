# LearningHub — Code Conventions

## Backend (Spring Boot 3.5 / Java 21 / MyBatis)

### Keep (existing patterns — all new code follows these)

- **Response wrapper**: every endpoint returns HTTP 200 with `BaseResponse{success, message, data, code}`; the real status lives in `code`. `GlobalExceptionHandler` maps every `CustomException` subclass to a 200 + error body.
- **Routing**: controllers are `@RestController` at `api/<area>/v1` (e.g. `api/exam/v1`).
- **DTOs**: request DTOs in `dtos/requests/<area>/` with snake_case `@JsonProperty`; response DTOs named `<Entity>Release` (full) / `<Entity>ReleaseCompact` (summary), produced by the model implementing `Releasable<T, C>`.
- **Aggregate service pattern** — one package per aggregate under `services/`:
  - `XxxService` — facade, `@Transactional`, orchestration only
  - `XxxQuery` — data access (wraps MyBatis mappers)
  - `XxxReader` — domain validation / mapping
  - `XxxListener` — side effects (notifications, contribution events, cascade rows)
  - `XxxACL implements IBaseACL` — `canCreate/canDelete/canEdit/canView`
- **Identity**: `AppContext` provides the current `userId` (principal is a `Long`) and roles.
- **IDs & time**: `BIGINT` identity ids; epoch-millis `createdAt`/`updatedAt` (`TimerUtil.now()`).

### Changed / new rules

- **Persistence = MyBatis** (JPA removed):
  - Mapper interfaces live in `repositories/<aggregate>/` (`@Mapper`), XML in `resources/mappers/<aggregate>/*.xml`. XML for anything beyond trivial CRUD; annotations allowed for one-liners.
  - Models are plain POJOs (Lombok + `Releasable` only — no JPA annotations).
  - `<insert useGeneratedKeys="true" keyProperty="id">` for identity ids; UUIDs (e.g. `Token`) generated in code via `UuidUtil.v7()`.
  - JSONB via TypeHandlers in `commons/typehandlers/`: `JsonbMapTypeHandler` (`Map<String,Object>`), `JsonbLongListTypeHandler` (`List<Long>`). Enums map as `VARCHAR` (default `EnumTypeHandler`).
  - `commons/mybatis/AuditInterceptor` auto-fills `created_at` on INSERT and `updated_at` on UPDATE — never set them by hand.
  - Pagination is **keyset (cursor) only** — no OFFSET, no PageHelper.
- **Schema = Flyway**: `src/main/resources/db/migration/V{n}__desc.sql`. MyBatis has no DDL generation; never edit a shipped migration, always add a new one.
- **Validation**: Bean Validation (`@NotBlank`, `@Size`, `@Email`, …) on request DTOs + `@Valid` in controllers for shape checks; `Reader` classes keep domain rules only. `MethodArgumentNotValidException` is handled centrally into `BaseResponse.error`.
- **Secrets**: only `${PLACEHOLDER}` references in `application.properties`; real values in gitignored `.env` (`spring.config.import=optional:file:.env[.properties]`). Ship `.env.example`.
- **OpenAPI**: springdoc annotations on all controllers; swagger-ui enabled in the dev profile only.
- **Tests**: JUnit 5 + Testcontainers (PG / Mongo / Redis / RabbitMQ). Integration tests extend `AbstractIntegrationTest` (`@SpringBootTest` + `@Testcontainers` + `@ServiceConnection`). Naming: `XxxServiceTest`, `XxxControllerIT`.

### API style

- Paths: `api/<area>/v1/...`, resources plural where listing (`/conversations`), actions as sub-paths (`/{id}/publish`).
- Methods: `GET` read, `POST` create/action, `PUT` update, `DELETE` remove/archive.
- Lists: cursor pagination — `?cursor=&limit=`; respond `{items, next_cursor}`.
- Request/response JSON is snake_case.

## Frontend (React 19 / Vite / TypeScript strict / MUI v7)

- **Server state = TanStack Query v5** for ALL API data (keys like `['posts','feed',cursor]`). Redux Toolkit holds **UI state only** (loading overlay, modals, layout).
- **Feature folders going forward**: new work in `src/features/<feature>/{api,components,hooks,types}`. Existing `apis/ components/ pages/ ...` layer folders remain as shared/legacy.
- **Auth**: httpOnly cookies are the truth — axios `withCredentials: true`; no tokens in localStorage, no Bearer header, no jwt-decode identity. Identity comes from `GET /api/user/v1/me`. On `code == 401`: call `POST /api/auth/v1/refresh` (deduped promise) and retry once.
- **Forms**: react-hook-form + zod (`zodResolver`).
- **Realtime**: `@stomp/stompjs` singleton in `src/lib/stompClient.ts`; components use the `useSubscription(destination, onMessage)` hook.
- **Code editor**: `@monaco-editor/react` (code questions only, lazy-loaded).
- **Styling**: MUI v7 components + Tailwind v4 utilities (existing hybrid); theme primary `#2463eb`.
- **Naming**: PascalCase components (`ExamBuilder.tsx`), hooks `useXxx`, query hooks `useFeedQuery` / `useSendMessageMutation`. Props typed as `I<Name>Props`.
- **Formatting**: Prettier — no semicolons, single quotes, `printWidth: 100`, import sort plugin. Path alias `@/` → `src/`.

## AI server (Python 3.12 / FastAPI)

- pydantic-settings for config (env-driven), `OLLAMA_API_KEY` for Ollama Cloud models, model name via `AI_MODEL` env.
- LangChain structured-output chains for grading; LangGraph + Mongo checkpoints for the chatbot.
- Consumes `grading.ai.jobs` via aio-pika (prefetch 1); results via HMAC-signed callback to BE; never exposed publicly.
- Student answers are always fenced as data in prompts (injection guard). Prompts are versioned (`prompt_version` echoed in results).

## Git

- **Master repo + submodules**: root `LearningHub/` holds docs/infra and pins `LearningHubBackend/`, `LearningHubFE/`, `ai-server/` as submodules. Commit flow: commit in the sub-repo first, then update the pin in the master repo.
- **Conventional Commits**: `feat: ...`, `fix: ...`, `chore: ...`, `docs: ...`, `refactor: ...`, `test: ...`.
- **Branches**: `feat/P1-4-friends-api`, `fix/P0-8-post-vote-objecttype` — plan task ids stay in branch names and commit messages.
- Never commit `.env` or secrets. Rotate anything that leaks.
