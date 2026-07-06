# LearningHub — Code Conventions

## Backend (Spring Boot / Java 21 / MyBatis)

### Package layout — standard Spring Boot, layered

Everything lives under `com.example.learninghub`, packaged **by layer** (not by feature/aggregate). The old per-aggregate pattern (`XxxService` + `XxxQuery` + `XxxReader` + `XxxListener` + `XxxACL` in `services/<aggregate>/`) is **retired** — do not reintroduce it.

```
com.example.learninghub
├── annotation/      custom annotations (@CurrentUser, @StrongPassword, @HexColor, matches/…)
├── aspect/          AOP aspects (LoggingAspect)
├── config/          @Configuration classes (SecurityConfig, WebConfig, SolrConfig, AsyncConfig, …)
│   └── mybatis/     MyBatis infra: AuditInterceptor + JSONB/UUID TypeHandlers
├── constants/       ApiPaths, AppRoutes, SolrConstant
├── controller/      @RestController classes — thin: validate, delegate, wrap in BaseResponse
├── enums/           shared enums (Role, VoteType, …)
├── event/           Spring ApplicationEvents (side effects go through these, not Listener classes)
├── exception/       CustomException hierarchy + GlobalExceptionHandler
├── health/          actuator HealthIndicators (SolrHealthIndicator)
├── mapper/          MapStruct mappers — XxxMapper, @Mapper(componentModel = "spring")
├── model/           ALL data shapes, split by role/store (mirrors repository/)
│   ├── sql/         persistence models (User, Post, …) extending BaseModel / AuditableModel
│   ├── solr/        Solr documents (TagDocument, SystemLogDocument)
│   ├── mongo/       (future) Mongo documents
│   ├── request/<area>/   request payloads, Bean Validation annotations
│   ├── response/<area>/  response payloads (UserInformation, UserCompact, …)
│   └── internal/    internal transfer objects (SystemLogDto)
├── repository/      data access, split by store (mirrors model/)
│   ├── sql/         MyBatis @Mapper interfaces (XxxRepository); XML in resources/mapper/
│   ├── solr/        Solr repositories (SolrClient wrappers)
│   └── mongo/       (future) Spring Data Mongo repositories
├── scheduler/       @Scheduled jobs (SystemLogScheduler)
├── security/        JwtFilter, JwtTokenizer, CustomUserDetails, UserDetailServiceImpl, CurrentUserArgumentResolver
│   └── authorization/  PermissionPolicy<T> strategies + DomainPermissionEvaluator (see Authorization)
├── service/         service interfaces (TagService, PostService, …)
│   └── impl/        implementations (TagServiceImpl, @Service, @Transactional)
└── utils/           static helpers (CommonUtil, CookieUtil, RequestUtil, SolrUtil, SolrQueryBuilder)
```

Request flow: **Controller → Service interface → ServiceImpl → Repository (MyBatis / Solr / Mongo)**.

### Core patterns (all new code follows these)

- **Response wrapper**: every endpoint returns HTTP 200 with `BaseResponse{success, code, message, data}`; the real status lives in `code`. `GlobalExceptionHandler` maps every `CustomException` subclass to a 200 + error body.
- **Routing**: controllers are `@RestController` at `api/<area>/v1` (e.g. `api/exam/v1`); path constants live in `constants/ApiPaths`.
- **Services**: interface in `service/`, implementation in `service/impl/`. Impls carry `@Service`, `@Transactional` and orchestration; controllers depend on the interface only.
- **Authorization** (SOLID, deny-by-default): method security on service impls via the standard Spring Security `PermissionEvaluator` contract —
  - Object checks: `@PreAuthorize("hasPermission(#post, 'EDIT')")`. `DomainPermissionEvaluator` routes the check to the `PermissionPolicy<T>` bean whose `targetType()` matches the target; one policy class per domain type (`PostPermissionPolicy`, `CommentPermissionPolicy`, `UserPermissionPolicy`, …) with its actions in a matching enum (`PostPermission`, …).
  - Pure role checks: `@PreAuthorize("hasRole('ADMIN')")` — no policy class.
  - Adding authorization for a new domain type = one new `PermissionPolicy` bean; nothing else changes (OCP). Never reintroduce SpEL bean-name calls (`@postAcl.canEdit(...)`).
- **Payload models**: request models in `model/request/<area>/` with snake_case `@JsonProperty`; response models in `model/response/<area>/` (e.g. `UserInformation` full / `UserCompact` summary). Model ↔ payload conversion is MapStruct's job (`mapper/`), never hand-rolled in services.
- **Identity**: the authenticated principal is an immutable `CustomUserDetails` (`security/`) carrying `id`, `username`, `fullName`, `email` and raw `roles` (no `ROLE_` prefix — the prefix exists only in `getAuthorities()`); use `hasRole(Role.ADMIN)` for checks in code. Built via `CustomUserDetails.from(User)` at login and from JWT claims (`userId`, `fullName`, `email`, `roles`) per request; injected into controllers via `@CurrentUser`.
- **IDs & time**: `BIGINT` identity ids; epoch-millis `createdAt`/`updatedAt`.

### Persistence (MyBatis, no JPA)

- Repository interfaces are `@Mapper`-scanned from `repository/sql/` (`@MapperScan("com.example.learninghub.repository.sql")`), named `XxxRepository`; XML in `resources/mapper/*.xml` (`mybatis.mapper-locations=classpath*:mapper/*.xml`). XML for anything beyond trivial CRUD; annotations allowed for one-liners.
- Persistence models are plain POJOs (Lombok, no JPA annotations) in `model/sql/`, extending `AuditableModel` (timestamps) or `BaseModel` (timestamps + `Long id`).
- `<insert useGeneratedKeys="true" keyProperty="id">` for identity ids; UUIDs (e.g. `Token`) generated DB-side (uuid v7 function).
- JSONB via TypeHandlers in `config/mybatis/` (`mybatis.type-handlers-package`): `JsonbMapTypeHandler` (`Map<String,Object>`), `JsonbLongListTypeHandler` (`List<Long>`). Enums map as `VARCHAR` (default `EnumTypeHandler`).
- `config/mybatis/AuditInterceptor` auto-fills `created_at` on INSERT and `updated_at` on UPDATE — never set them by hand.
- Pagination is **keyset (cursor) only** — no OFFSET, no PageHelper.
- **Schema = Flyway**: `src/main/resources/db/migration/V{n}__desc.sql`. MyBatis has no DDL generation; never edit a shipped migration, always add a new one.

### Cross-cutting rules

- **Validation**: Bean Validation (`@NotBlank`, `@Size`, `@Email`, …) on request DTOs + `@Valid` in controllers for shape checks; domain rules live in the service impls. `MethodArgumentNotValidException` is handled centrally into `BaseResponse.error`.
- **Secrets**: only `${PLACEHOLDER}` references in `application.properties`; real values in gitignored `.env` (`spring.config.import=optional:file:.env[.properties]`). Ship `.env.example`.
- **OpenAPI**: springdoc annotations on all controllers; swagger-ui enabled in the dev profile only.
- **Tests**: JUnit 5 + Testcontainers (PG / Mongo / Redis / RabbitMQ). Integration tests extend `AbstractIntegrationTest` (`@SpringBootTest` + `@Testcontainers` + `@ServiceConnection`). Naming: `XxxServiceTest`, `XxxControllerIT`. Test packages mirror main packages (`service/impl/`, `repository/sql/`, `model/sql/`).

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
