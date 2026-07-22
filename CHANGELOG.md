# Changelog

## [0.1.41] - 2026-07-22
### Added
- `Runners::Traces#erase_partner!(identity:)` — deletes all traces tagged `partner:<identity>` and `owner:<identity>`; returns `{ erased: true, identity:, count: }`. Prep for H8 death protocol cascade (Phase 4.5 contract gate gap).

## [0.1.40] - 2026-06-17
### Fixed
- **Critical performance fix:** Trace store `snapshot_dirty_state` no longer serializes ALL traces to JSON on every flush — replaced boolean `@traces_dirty` flag with per-trace `@dirty_trace_ids` Set so only modified traces are serialized (O(changed) instead of O(total))
- `load_from_local` no longer re-serializes every trace on boot — stores raw DB rows directly in `@persisted_trace_rows`
- `persist_dirty_traces` now handles explicit deletion tracking via `@deleted_trace_ids` Set
- Eliminates 97%+ single-core CPU usage caused by `decay_cycle` triggering full-store JSON serialization every 60 seconds

## [0.1.39] - 2026-06-01
### Fixed
- `ErrorTracer` now guards against infinite recursion — if downstream trace storage triggers error/fatal logging, the `tracing?` thread-local flag prevents re-entry
- `ErrorTracer` background worker thread now terminates cleanly — `setup` registers an `at_exit` hook, and a new `shutdown` method pushes the `:stop` sentinel to the queue (previously the thread ran forever with no shutdown path)
- `HotTier.serialize_trace` now preserves all trace fields (was only serializing 9 out of 25+) — adds `base_decay_rate`, `emotional_valence`, `emotional_intensity`, `origin`, `source_agent_id`, `domain_tags`, `associated_traces`, `child_trace_ids`, `reinforcement_count`, `unresolved`, `consolidation_candidate`, `last_decayed`, `created_at`, `encryption_key_id`, `parent_trace_id`
- `HotTier.deserialize_trace` reconstructs all fields with proper type coercion (arrays via JSON, booleans, integers, symbols, timestamps)
- `PostgresStore#deserialize_trace` now reads `child_trace_ids` from the DB column instead of hardcoding `[]` — children are no longer silently lost on retrieval
- `PostgresStore#serialize_trace` now writes `child_trace_ids` to the DB row
- `PostgresStore#map_update_fields` now maps `child_trace_ids` to the `:child_trace_ids` column (was `nil`, silently dropping partial updates)
- `PostgresStore#retrieve_by_domain` uses PostgreSQL JSONB `@>` containment operator for exact array-member matching instead of `LIKE` — eliminates full table scans and substring false positives (e.g., `%auth%` matching `oauth`)
- `Consolidation#erase_by_type` now uses `batch_delete_by_type` on PostgresStore, avoiding loading all matching traces into Ruby memory before deleting one-by-one (O(100k) heap allocation → O(1) SQL delete)

## [0.1.38] - 2026-05-27
### Fixed
- `PostgresStore#parse_json_or_raw` now requires matching start/end delimiters (`{}`/`[]`) before attempting JSON parse — eliminates 100k+/day error log spam from bracket-prefixed text content (e.g. `[trace_persistence] ...`) that triggered a self-amplifying feedback loop via RabbitMQ logging
- `PostgresStore#parse_json_array` applies same delimiter guard
- Removed error-level logging from JSON parse fallback path — non-parseable content is the expected "or_raw" code path, not an error condition

## [0.1.37] - 2026-05-17
### Added
- `Memory::Diary` sub-module — per-agent chronological session diary with write, read, and search.
- `DiaryStore` backed by `Legion::Data::Local` (SQLite) with agent-scoped isolation.
- Local migration `20260517000001_create_memory_diary_entries` for diary table.
- `Diary::Client` and `Runners::Diary` for runner integration (write_diary, read_diary, search_diary, diary_stats).
- Module-level convenience API: `Memory::Diary.write`, `.read`, `.search`.

## [0.1.36] - 2026-05-17
### Fixed
- `PostgresStore#db_ready?` now checks `Legion::Data.can_write?(:memory_traces)` before attempting writes, preventing `PG::InsufficientPrivilege` errors when connected with a read-only role.
- `Trace.postgres_available?` also checks INSERT privilege so `create_store` correctly falls back to a local store instead of selecting PostgresStore and failing at runtime.

## [0.1.34] - 2026-05-08
### Fixed
- Deferred GAIA heartbeat maintenance no longer initializes the shared trace store just to return a deferred summary, avoiding idle local trace table scans.
- `Store#parse_db_content` now returns bracket-prefixed raw trace/log text without JSON parse attempts or malformed JSON debug noise while still parsing real JSON objects and arrays.

## [0.1.35] - 2026-05-15
### Fixed
- Normalize trace affect fields before persisting through in-memory, cache, local SQLite, and Postgres stores so string-backed values do not crash or silently collapse to `0.0`.
- Preserve numeric `emotional_valence` across local trace persistence and normalize legacy structured payloads when they are reloaded.

## [0.1.33] - 2026-05-07
### Fixed
- `PostgresStore#parse_json_or_raw` no longer attempts JSON parse on plain-text content — checks for `{`/`[` prefix before parsing, eliminating ERROR log spam during bulk reads with mixed content types
- `PostgresStore#parse_json_array` now guards against nil/empty strings before parsing
- `Store#parse_db_json` now short-circuits on nil/empty columns (domain_tags, associations, child_ids, emotional_valence) before attempting parse, fixing ERROR spam on traces with sparse optional fields

## [0.1.32] - 2026-05-07
### Fixed
- Trace association retrieval now snapshots associated traces under the store mutex before filtering.
- Local trace restore preserves symbol keys for JSON fields that are consumed as symbol-keyed hashes.

## [0.1.31] - 2026-04-27
### Added
- Add a heuristic pre-compaction memory save path and synchronous pre-compaction event listeners for `chat.pre_compact`, `context.pre_compact`, and `conversation.pre_compact`.

### Fixed
- Require `legion/logging` and `legion/cache/helper` before `CacheStore` includes helper APIs, preventing `log` or cache helper methods from being skipped when the file is loaded directly.
- Pass `CacheStore` TTL values through `cache_set` as keywords so flushes work with the shared cache helper API.

## [0.1.30] - 2026-04-27
### Fixed
- Local trace persistence now writes only changed trace rows instead of upserting every trace in the partition for a one-trace update.
- Local association persistence now stores `partition_id` and restores associations by partition, avoiding a startup query with one giant trace-id `IN (...)` list.

## [0.1.29] - 2026-04-22
### Fixed
- `parse_db_content` no longer attempts JSON parse on plain-text content — checks for `{`/`[` prefix before parsing, returns raw string for non-JSON content without logging errors

## [0.1.28] - 2026-04-22
### Fixed
- Snapshot save/restore now logs warnings when Self/Affect module methods are unavailable instead of silently skipping
- 26+ silent rescue blocks in trace persistence layer (postgres_store, store, hot_tier) now log errors via `log.error`
### Changed
- CLAUDE.md updated to document all 16 actors (was 5) and CommunicationPattern sub-module

## [0.1.27] - 2026-04-17
### Fixed
- Add missing `Legion::Logging::Helper` include to `CacheStore` — resolves `NameError: undefined local variable or method 'log'` crash on startup when Memcached is available (#23)

## [0.1.26] - 2026-04-15
### Changed
- Set `mcp_tools?`, `mcp_tools_deferred?`, and `transport_required?` to `false` — internal cognitive pipeline extension

## [Unreleased]

### Fixed
- fix retrieve_ranked to return Hash with traces key instead of bare Array for GAIA phase wiring
- add respond_to? guards in Quota#enforce! for store methods not present on all backends
- add lazy default_engine initialization in CognitiveImmuneMemory runner

## [0.1.24] - 2026-04-03

### Fixed
- Wrap `save_to_local` persist in a single SQLite transaction — 32K individual lock acquisitions become 1
- Use `insert_conflict(:replace)` instead of SELECT-then-INSERT/UPDATE per trace

## [0.1.23] - 2026-04-03

### Fixed
- Sanitize trace content before SQLite persist: force-decode to BINARY then re-encode UTF-8, strip null bytes — prevents `unrecognized token` SQL errors from unescaped characters

## [0.1.22] - 2026-04-03

### Changed
- Refactor `Store#save_to_local` into `snapshot_dirty_state`, `persist_dirty_traces`, `persist_dirty_associations`, and `clear_dirty_flags` helpers to reduce cyclomatic/perceived complexity
- Restructure `Consolidation#decay_cycle` early return to satisfy `RunnerReturnHash` cop
- Add exception capture and logging to `Consolidation#trace_count` rescue clause

## [0.1.21] - 2026-04-01

### Changed
- `ErrorTracer.record_trace` now dispatches `Trace.shared_store` writes/flushes in a background `Thread.new` — error/fatal logging hooks no longer block the calling Puma thread, regardless of store backend (Postgres, CacheStore, or in-memory)
- Debounce check remains synchronous; only the store write and flush go async

## [0.1.20] - 2026-03-31

### Added
- CommunicationPattern sub-module for Phase C relational intelligence
- PatternAnalyzer: time-of-day/day-of-week histograms, channel preference, topic clustering, consistency scoring
- CommunicationPattern runner: update_patterns, analyze_patterns, pattern_stats
- Apollo Local persistence for communication pattern state

## [0.1.19] - 2026-03-31

### Fixed
- `postgres_store.retrieve_by_domain` now accepts `min_strength:` keyword to match in-memory store interface
- `postgres_store.all_traces` now accepts `min_strength:` keyword to match in-memory store interface
- Both methods now filter by strength in the SQL query for consistency with Store and CacheStore

## [0.1.18] - 2026-03-30

### Fixed
- fix `NameError: undefined local variable or method 'log'` in ErrorTracer.setup by replacing `log.info` with `Legion::Logging.info` — singleton module context has no `Legion::Logging::Helper` mixin

## [0.1.17] - 2026-03-30

### Changed
- update to rubocop-legion 0.1.7, resolve all offenses

## [0.1.16] - 2026-03-29

### Fixed
- Add `=> e` capture and `Legion::Logging.error` call to all bare `rescue StandardError` clauses in `memory.rb` to satisfy rescue-logging lint rule
- Fix `Lint/ShadowedException` in `snapshot.rb`: replace `rescue NameError, NoMethodError` with `rescue NameError` (`NoMethodError` is a subclass of `NameError`)
- Refactor `Snapshot#distribute_state` into dedicated helper methods to reduce cyclomatic/perceived complexity below threshold

## [0.1.15] - 2026-03-26

### Changed
- fix remote_invocable? to use class method for local dispatch

## [0.1.14] - 2026-03-26

### Fixed
- `PostgresStore#serialize_trace` and `#map_update_fields` now strip null bytes (`\x00`) from all string fields before INSERT/UPDATE. PostgreSQL text columns reject null bytes, causing `string contains null byte` errors when content from external sources (e.g., Teams Graph API) contains embedded nulls

## [0.1.13] - 2026-03-26

### Fixed
- `PostgresStore#serialize_trace` omitted `agent_id` column, causing `PG::NotNullViolation` on every insert against PostgreSQL (migration 022 declares `agent_id null: false`). Constructor now accepts `agent_id:` with fallback to `Legion::Settings.dig(:agent, :id)` or `'default'`
- `Trace.create_store` factory now resolves and passes `agent_id` to PostgresStore
- Spec schema for PostgresStore now includes `agent_id` column matching production migration

## [0.1.12] - 2026-03-26

### Fixed
- `PostgresStore#store` used SQLite-specific `insert_conflict(:replace)` which fails on PostgreSQL with `TypeError: no implicit conversion of Symbol into Integer`. Replaced with proper `insert_conflict(target: :trace_id, update: ...)` syntax that generates correct `ON CONFLICT` SQL

## [0.1.11] - 2026-03-25

### Added
- `Helpers::HotTier` module: Redis hot-tier cache in front of PostgresStore using `Legion::Cache::RedisHash`. Stores traces as Redis hashes with 24-hour TTL, maintains a sorted-set index per tenant, and provides `cache_trace`, `fetch_trace`, and `evict_trace` operations
- `PostgresStore#retrieve` checks hot tier first; falls through to DB on miss and populates hot tier on DB hit
- `PostgresStore#store` writes through to hot tier after successful DB write
- `PostgresStore#delete` evicts from hot tier before DB delete
- `PostgresStore#update` evicts stale hot-tier entry after DB update
- 32 new specs covering HotTier interface, serialize/deserialize round-trip, availability guard, and all four PostgresStore integration points

## [0.1.10] - 2026-03-25

### Added
- `Helpers::PostgresStore`: write-through durable store backed by Legion::Data (PostgreSQL or MySQL), scoped by tenant_id. Implements full store interface: store, retrieve, retrieve_by_type, retrieve_by_domain, all_traces, delete, update, record_coactivation, associations_for, walk_associations, delete_lowest_confidence, delete_least_recently_used, firmware_traces, flush (no-op), db_ready?
- `create_store` in `Trace` module now selects PostgresStore when a PostgreSQL or MySQL connection is available with both required tables; falls back to CacheStore or in-memory Store
- `postgres_available?` and `resolve_tenant_id` private helpers on `Trace` module
- 46 new specs covering all PostgresStore methods using an in-memory SQLite DB

## [0.1.9] - 2026-03-25

### Added
- Periodic actors for 10 sub-modules: Archaeology (decay), Compression (maintenance), Echo (decay), EchoChamber (decay), ImmuneMemory (decay), Nostalgia (maintenance), Palimpsest (decay), Reserve (maintenance), SemanticPriming (decay), SemanticSatiation (recovery) (closes #1)
- Quota enforcement actor for Trace (runs every 300s, calls enforce_quota) (closes #2)
- Runner methods: `decay_all` for Archaeology and EchoChamber, `enforce_quota` for Trace::Consolidation

### Fixed
- Add Mutex synchronization to trace Store and CacheStore for thread safety during concurrent tick cycles

## [0.1.7] - 2026-03-24

### Fixed
- Add Mutex synchronization to CacheStore for thread-safety across concurrent store/iterate/flush operations
- Add rescue blocks to `flush_associations` and `flush_index` for graceful handling of oversized cache entries

## [0.1.6] - 2026-03-23

### Fixed
- Fix trace migration path registration (`'memory/local_migrations'` -> `'trace/local_migrations'`)
- Refactor CacheStore from single-blob storage to per-trace individual cache keys with index, preventing OOM on flush

### Changed
- CacheStore now uses `legion:memory:trace:<uuid>` keys instead of serializing all traces into one key
- Dirty set tracking replaces dirty flag for more efficient selective flushing
- Batch flush in groups of 500 traces

## [0.1.5] - 2026-03-22

### Changed
- Add legion-logging, legion-settings, legion-json, legion-cache, legion-crypt, legion-data, legion-transport as runtime dependencies
- Update spec_helper with real sub-gem helper stubs replacing manual Legion::Logging and Helpers::Lex stubs

## [0.1.3] - 2026-03-22

### Fixed
- Fix `Trace::Helpers::Decay` crash when `last_reinforced` is a String after cache round-trip (added `ensure_time` coercion in `compute_storage_tier` and `compute_retrieval_score`)

## [0.1.2] - 2026-03-20

### Added
- `Trace::Helpers::Snapshot`: cognitive state persistence with MessagePack serialization and SHA-512/Ed25519 signing
- Snapshot save, restore, list, and prune operations with auto-prune on save
- GAIA lifecycle hooks: auto-save on `service.shutting_down`, auto-restore on `gaia.started`
- `msgpack` gem dependency

## [0.1.1] - 2026-03-18

### Changed
- Enforce NODE_TYPES validation in SemanticPriming::PrimingNetwork#add_node (returns nil for invalid types)

## [0.1.0] - 2026-03-18

### Added
- Initial release as domain consolidation gem
- Consolidated source extensions into unified domain gem under `Legion::Extensions::Agentic::<Domain>`
- All sub-modules loaded from single entry point
- Full spec suite with zero failures
- RuboCop compliance across all files
