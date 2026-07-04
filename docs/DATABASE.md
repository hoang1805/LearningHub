# LearningHub — Database Design

Three stores, each with a clear role. **Source of truth is always PostgreSQL (relational) or MongoDB (documents); Redis holds only ephemeral/derivable state.**

## Data placement

| Store | Data | Why |
|---|---|---|
| **PostgreSQL** | users, profiles, sessions, tokens, friendships, groups + membership, posts, comments, votes, files metadata, contribution events + score, role requests, moderation, ALL exam tables | FKs, transactions — exam scoring needs constraint-grade integrity. Flyway-managed, MyBatis-accessed. |
| **MongoDB** | chat_conversations, chat_messages, notifications, proctor_events (anti-cheat log), ai_conversations / ai_messages + LangGraph checkpoints | High-volume append-mostly, flexible payloads, TTL retention; keeps PG lean. |
| **Redis** | presence, leaderboards (ZSET), attempt deadlines (ZSET for auto-submit sweeper), unread counters, daily contribution caps, rate-limit buckets, caches | Ephemeral/derivable; everything rebuildable from PG/Mongo. |
| **RabbitMQ** | grading job queues (`grading.code.jobs`, `grading.ai.jobs` + DLQs) and STOMP relay traffic | Durable, ack-based delivery with DLX; doubles as the WS broker. |

**Conventions:** PG uses `BIGINT` identity ids + epoch-millis `created_at`/`updated_at` (matches `BaseModel`). Mongo uses `ObjectId` (time-ordered → doubles as the pagination cursor). Enums stored as `VARCHAR`. Flat JSON config lives in `JSONB` columns handled by MyBatis TypeHandlers. **Flyway owns the schema** — `V{n}__desc.sql`, no ORM DDL generation.

## PostgreSQL

### Existing tables (recreated in Flyway `V1` with fixes)

`users`, `sessions`, `tokens`, `votes`, `groups`, `group_members`, `group_invitations`, `group_requests`, `posts`, `comments`.

Changes vs the old MySQL/JPA schema:
- `groups.members` JSON column **dropped** — `group_members` rows are the single source of truth.
- `users` additions: `status VARCHAR (ACTIVE|BANNED)` default ACTIVE, `banned_until BIGINT NULL`, `contribution_score NUMERIC(12,2)` default 0, `lifetime_points NUMERIC(12,2)` default 0.

### New tables — social / platform

| Table | Key columns |
|---|---|
| `user_profiles` | `user_id` PK→users, `avatar_file_id`, `cover_file_id`, `bio`, `school`, `birthday`, `links JSONB` |
| `friendships` | `requester_id`, `addressee_id`, `status (PENDING\|ACCEPTED\|REJECTED)`; unique index on `(LEAST(requester_id,addressee_id), GREATEST(...))` — one row per pair |
| `files` | `uploader_id`, `bucket`, `object_key`, `original_name`, `mime_type`, `size_bytes`, `checksum`, `status (UPLOADING\|READY\|DELETED)`, `scope` |
| `attachments` | `file_id`→files, `object_type` (reuse `ObjectType` enum), `object_id`; index `(object_type, object_id)` |
| `role_requests` | `user_id`, `requested_role`, `note`, `status (PENDING\|APPROVED\|REJECTED)`, `reviewer_id`, `reviewed_at` |
| `moderation_actions` | `target_user_id`, `actor_id`, `action (BAN\|UNBAN\|ROLE_GRANT\|ROLE_REVOKE)`, `reason`, `expires_at` |
| `contribution_events` | `user_id`, `event_type`, `weight NUMERIC(6,2)`, `object_type`, `object_id`, `dedupe_key VARCHAR UNIQUE NULL` (exact unvote compensation); index `(user_id, created_at)` |

### New tables — exam engine

| Table | Key columns |
|---|---|
| `exams` | `creator_id`, `group_id NULL`, `title`, `description`, `mode (PRACTICE\|EXAM)`, `status (DRAFT\|PUBLISHED\|ONGOING\|CLOSED\|ARCHIVED)`, `open_at`, `close_at`, `duration_minutes`, `settings JSONB` — see below |
| `exam_sections` | `exam_id`, `title`, `description`, `order_index`, `settings JSONB` |
| `questions` | `creator_id`, `type (ONE_CHOICE\|MULTI_CHOICE\|SHORT_ANSWER\|LONG_ANSWER\|CODE)`, `current_version_id`, `status`, `tags` — question-bank head row |
| `question_versions` | `question_id`, `version_no`, `content`, `config JSONB`, `answer JSONB`, `explanation` — **immutable; every edit inserts a new row**. `answer` is always stripped from candidate-facing DTOs |
| `exam_questions` | `exam_id`, `section_id`, `question_id`, `question_version_id` (pinned at publish), `points`, `order_index`, `settings_override JSONB` |
| `exam_members` | `exam_id`, `user_id`, `role (CANDIDATE\|SCORER\|MANAGER)`, `status`; unique `(exam_id, user_id)`; **SCORER/MANAGER can never create an attempt** |
| `exam_attempts` | `exam_id`, `user_id`, `attempt_no`, `status (IN_PROGRESS\|SUBMITTED\|GRADING\|GRADED\|EXPIRED)`, `started_at`, `submitted_at`, `deadline_at` (personal deadline incl. extensions; NULL in practice), `total_score`, `max_score`, `meta JSONB` |
| `attempt_answers` | `attempt_id`, `exam_question_id`, `question_version_id` (**copied at attempt start — in-flight attempts keep their version**), `answer JSONB`, `saved_at`, `auto_score`, `final_score`, `grading_status (NONE\|AUTO_DONE\|AI_PENDING\|AI_DONE\|MANUAL_PENDING\|MANUAL_DONE\|FAILED)`; unique `(attempt_id, exam_question_id)` — autosave = upsert |
| `code_submissions` | `attempt_answer_id`, `language_id`, `source_code`, `judge0_tokens JSONB`, `status`, `passed_tests`, `total_tests`, `score`, `is_final` |
| `grading_records` | `attempt_answer_id`, `grader_type (AUTO\|AI\|MANUAL)`, `grader_id`, `score`, `feedback`, `model_info JSONB`, `superseded BOOL` — full audit trail; latest non-superseded wins |
| `exam_announcements` | `exam_id`, `author_id`, `message` |
| `exam_time_adjustments` | `exam_id`, `attempt_id NULL` (NULL = whole exam), `delta_minutes` / `new_close_at`, `actor_id`, `reason` |

### `exams.settings` JSONB

```jsonc
{
  "shuffle_questions": false,
  "shuffle_options": false,
  "max_attempts": 1,                    // default 1 in EXAM mode
  "grade_policy": "BEST",               // BEST | FIRST | LAST (default BEST)
  "reveal_policy": "AFTER_CLOSE",       // NEVER | AFTER_SUBMIT | AFTER_CLOSE | IMMEDIATE (practice)
  "anti_cheat": {
    "log_tab_switch": true,
    "block_copy_paste": false,
    "require_fullscreen": false,
    "max_violations_warn": 3,           // warn candidate at this count
    "auto_flag": true,                  // decided ON: violations flag the attempt
    "max_violations_submit": 5          // force-submit threshold; 0 = off
  },
  "ai_grading_enabled": true,
  "code_scoring": "ON_SUBMIT",          // ON_SUBMIT | AT_END
  "code_first_submission_only": false,
  "results_visible": "AFTER_CLOSE"
}
```

### `question_versions.config` JSONB per type

| Type | Config |
|---|---|
| ONE_CHOICE / MULTI_CHOICE | `{options: [{key, text}], scoring: ALL_OR_NOTHING \| PARTIAL}` (PARTIAL = selectedCorrect / totalCorrect) |
| SHORT_ANSWER | `{answer_kind: NUMBER \| TEXT, max_length, case_sensitive, trim, accepted: [...], numeric_tolerance}` |
| LONG_ANSWER | `{max_length, rubric}` |
| CODE | `{languages: [judge0_ids], starter_code: {lang: src}, test_cases: [{input, expected, weight, hidden}], cpu_time_limit, memory_limit}` |

## MongoDB collections

| Collection | Shape / indexes |
|---|---|
| `chat_conversations` | `{type: DIRECT\|GROUP, directKey "lo:hi" unique (DIRECT only), name, groupId (auto-created channel per learning Group), members: [{userId, role, lastReadMessageId, lastReadAt, muted}], createdBy, lastMessage: {messageId, senderId, preview, at}}`; index `members.userId` + `lastMessage.at desc` |
| `chat_messages` | `{conversationId, senderId, type TEXT\|FILE\|SYSTEM, content, attachments: [fileId], replyToId, createdAt, editedAt, deletedAt}`; index `(conversationId, _id desc)` — ObjectId = cursor; **no TTL** (retained indefinitely, soft-delete via `deletedAt`) |
| `notifications` | `{userId, type (FRIEND_REQUEST, POST_COMMENT, COMMENT_REPLY, GROUP_INVITE, EXAM_INVITE, EXAM_GRADED, EXAM_ANNOUNCEMENT, ROLE_APPROVED, AI_GRADE_READY, …), actorId, objectType, objectId, data, isRead}`; indexes `(userId, isRead)`, `(userId, createdAt desc)`; **TTL 180d** |
| `proctor_events` | `{examId, attemptId, userId, type (TAB_BLUR, TAB_FOCUS, VISIBILITY_HIDDEN, COPY, PASTE, FULLSCREEN_EXIT, DISCONNECT, RECONNECT, HEARTBEAT_MISS), at, severity (INFO\|WARN\|ALERT), meta}`; index `(examId, attemptId, at)`; **TTL 180d** |
| `ai_conversations` / `ai_messages` | per-user chatbot history + LangGraph checkpoints (owned by the Python server); retained until the user deletes |

## Redis key map

| Key | Type | Purpose |
|---|---|---|
| `presence:{userId}` | STRING, TTL 60s | Online status (refreshed by WS heartbeat) |
| `lb:global`, `lb:group:{groupId}` | ZSET | Contribution leaderboards (projection of PG events) |
| `attempt_deadlines` | ZSET (score = deadline millis, member = attemptId) | Auto-submit sweeper polls every 5s |
| `unread:{userId}` | HASH convId→count | Chat badges |
| `contrib:cap:{userId}:{eventType}:{yyyymmdd}` | INCR, TTL 48h | Daily anti-farm caps |
| `rl:*` | bucket4j-redis | Distributed rate limits (Phase 4) |

Grading job queues live on **RabbitMQ**, not Redis (see ARCHITECTURE.md).

## Contribution score

Weights stored per event in `contribution_events.weight` (tunable without breaking history):

| Event | Weight | Cap |
|---|---|---|
| POST_CREATED | +5 | 4/day |
| COMMENT_CREATED | +2 | 10/day |
| POST_UPVOTE_RECEIVED | +3 | self-votes excluded; unvote emits −3 via `dedupe_key` |
| COMMENT_UPVOTE_RECEIVED | +2 | — |
| DOWNVOTE_RECEIVED | −1 | per-object floor 0 |
| PRACTICE_COMPLETED | +3 | 3/day |
| EXAM_COMPLETED | +10 | once per exam |
| EXAM_SCORE_BONUS | +round(20 × score/max) | first attempt only |

- `display_score = Σ weight × 0.5^(age_days / 90)` — 90-day half-life, leaderboard reflects current engagement.
- `lifetime_points = Σ weight` — all-time stat shown on the profile.
- Write path: domain services publish Spring `ApplicationEvent`s → `ContributionListener` inserts `contribution_events` (caps via Redis INCR), then instantly `ZINCRBY lb:global` + `users.contribution_score += weight`.
- Reconcile path: nightly `@Scheduled` job recomputes exact decayed scores from the event table and rebuilds the ZSETs. **Source of truth = PG events; Redis = projection.**
