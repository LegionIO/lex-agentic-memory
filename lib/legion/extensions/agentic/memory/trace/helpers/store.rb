# frozen_string_literal: true

require 'json'

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          module Helpers
            # In-memory store for development and testing.
            # Production deployments should use a PostgreSQL + Redis backed store.
            class Store
              include Legion::Logging::Helper if defined?(Legion::Logging::Helper)

              ASSOCIATION_LOAD_BATCH_SIZE = 500

              attr_reader :traces, :associations

              def initialize(partition_id: nil)
                @mutex = Mutex.new
                @traces = {}
                @associations = Hash.new { |h, k| h[k] = Hash.new(0) }
                @partition_id = partition_id || resolve_partition_id
                @dirty_trace_ids = Set.new
                @deleted_trace_ids = Set.new
                @associations_dirty = false
                @persisted_trace_rows = {}
                load_from_local
              end

              def store(trace)
                persisted_trace = Helpers::Trace.normalize_trace_affect(trace)
                persisted_trace[:partition_id] ||= @partition_id
                @mutex.synchronize do
                  @dirty_trace_ids << persisted_trace[:trace_id]
                  @traces[persisted_trace[:trace_id]] = persisted_trace
                end
                persisted_trace[:trace_id]
              end

              def get(trace_id)
                @mutex.synchronize { @traces[trace_id] }
              end

              def delete(trace_id)
                @mutex.synchronize do
                  removed_trace = @traces.delete(trace_id)
                  @traces.each_value do |trace|
                    @dirty_trace_ids << trace[:trace_id] if trace[:associated_traces]&.delete(trace_id)
                  end

                  removed_links = @associations.delete(trace_id)
                  @associations.each_value { |links| links.delete(trace_id) }

                  if removed_trace
                    @dirty_trace_ids.delete(trace_id)
                    @deleted_trace_ids << trace_id
                  end
                  @associations_dirty = true if removed_trace || removed_links
                end
              end

              def retrieve_by_type(type, min_strength: 0.0, limit: 100)
                snapshot = @mutex.synchronize { @traces.values }
                snapshot.select { |t| t[:trace_type] == type && t[:strength] >= min_strength }
                        .sort_by { |t| -t[:strength] }
                        .first(limit)
              end

              def retrieve_by_domain(domain_tag, min_strength: 0.0, limit: 100)
                snapshot = @mutex.synchronize { @traces.values }
                snapshot.select { |t| t[:domain_tags].include?(domain_tag) && t[:strength] >= min_strength }
                        .sort_by { |t| -t[:strength] }
                        .first(limit)
              end

              def retrieve_associated(trace_id, min_strength: 0.0, limit: 20)
                associated = @mutex.synchronize do
                  trace = @traces[trace_id]
                  next [] unless trace

                  trace[:associated_traces].filter_map { |id| @traces[id]&.dup }
                end

                associated
                  .select { |t| t[:strength] >= min_strength }
                  .sort_by { |t| -t[:strength] }
                  .first(limit)
              end

              def record_coactivation(trace_id_a, trace_id_b)
                return if trace_id_a == trace_id_b

                @mutex.synchronize do
                  @associations[trace_id_a][trace_id_b] += 1
                  @associations[trace_id_b][trace_id_a] += 1
                  @associations_dirty = true

                  threshold = Helpers::Trace::COACTIVATION_THRESHOLD
                  if @associations[trace_id_a][trace_id_b] >= threshold && link_traces(trace_id_a, trace_id_b)
                    @dirty_trace_ids << trace_id_a
                    @dirty_trace_ids << trace_id_b
                  end
                end
              end

              def all_traces(min_strength: 0.0)
                snapshot = @mutex.synchronize { @traces.values }
                snapshot.select { |t| t[:strength] >= min_strength }
              end

              def count
                @mutex.synchronize { @traces.size }
              end

              def synchronize(&) = @mutex.synchronize(&)

              def firmware_traces
                retrieve_by_type(:firmware)
              end

              def flush
                save_to_local
              end

              def restore_traces(traces)
                snapshot = Array(traces).each_with_object({}) do |trace, memo|
                  next unless trace.is_a?(Hash) && trace[:trace_id]

                  restored = Helpers::Trace.normalize_trace_affect(trace)
                  restored[:partition_id] ||= @partition_id
                  memo[restored[:trace_id]] = restored
                end

                @mutex.synchronize do
                  @traces = snapshot
                  @associations = Hash.new { |h, k| h[k] = Hash.new(0) }
                  @dirty_trace_ids = Set.new(@traces.keys)
                  @deleted_trace_ids = Set.new
                  @associations_dirty = true
                end
                flush
              end

              def walk_associations(start_id:, max_hops: 12, min_strength: 0.1)
                snapshot = @mutex.synchronize { @traces.dup }
                return [] unless snapshot.key?(start_id)

                results  = []
                visited  = Set.new([start_id])
                queue    = [[start_id, 0, [start_id]]]

                until queue.empty?
                  current_id, depth, path = queue.shift
                  next unless (current = snapshot[current_id])

                  current[:associated_traces].each do |neighbor_id|
                    next if visited.include?(neighbor_id)

                    neighbor = snapshot[neighbor_id]
                    next unless neighbor
                    next unless neighbor[:strength] >= min_strength

                    visited << neighbor_id
                    neighbor_path = path + [neighbor_id]
                    results << { trace_id: neighbor_id, depth: depth + 1, path: neighbor_path }
                    queue << [neighbor_id, depth + 1, neighbor_path] if depth + 1 < max_hops
                  end
                end

                results
              end

              def save_to_local
                return unless defined?(Legion::Data::Local) && Legion::Data::Local.connected?
                return unless Legion::Data::Local.connection.table_exists?(:memory_traces)

                db = Legion::Data::Local.connection
                snapshots = snapshot_dirty_state
                return unless snapshots

                traces_snapshot, associations_snapshot, trace_rows_snapshot, trace_changes, associations_dirty = snapshots
                db.transaction do
                  scoped_trace_ids = db[:memory_traces].where(partition_id: @partition_id).select_map(:trace_id)
                  memory_trace_ids = traces_snapshot.keys
                  stale_ids = scoped_trace_ids - memory_trace_ids
                  persist_dirty_traces(db, trace_rows_snapshot, trace_changes, stale_ids)
                  persist_dirty_associations(db, associations_snapshot, scoped_trace_ids, memory_trace_ids, stale_ids, associations_dirty)
                end
                clear_dirty_flags(trace_rows_snapshot)
              end

              def snapshot_dirty_state
                @mutex.synchronize do
                  dirty_ids = @dirty_trace_ids.to_a
                  deleted_ids = @deleted_trace_ids.to_a
                  associations_dirty = @associations_dirty

                  return nil if dirty_ids.empty? && deleted_ids.empty? && !associations_dirty

                  dirty_rows = dirty_ids.each_with_object({}) do |trace_id, h|
                    trace = @traces[trace_id]
                    h[trace_id] = serialize_trace_for_db(trace) if trace
                  end

                  trace_rows_snapshot = @persisted_trace_rows.merge(dirty_rows)
                  deleted_ids.each { |id| trace_rows_snapshot.delete(id) }

                  traces_snapshot = @traces.transform_values(&:dup)
                  as = @associations.each_with_object({}) { |(tid, targets), memo| memo[tid] = targets.dup }
                  trace_changes = { dirty: true, changed_ids: dirty_ids, deleted_ids: deleted_ids }

                  [traces_snapshot, as, trace_rows_snapshot, trace_changes, associations_dirty]
                end
              end

              def persist_dirty_traces(db, trace_rows_snapshot, trace_changes, stale_ids)
                changed_ids = trace_changes[:changed_ids] || []
                deleted_ids = trace_changes[:deleted_ids] || []
                all_removals = (stale_ids + deleted_ids).uniq
                return if changed_ids.empty? && all_removals.empty?

                ds = db[:memory_traces]
                changed_ids.each do |trace_id|
                  row = trace_rows_snapshot[trace_id]
                  ds.insert_conflict(:replace).insert(row) if row
                end
                db[:memory_traces].where(trace_id: all_removals).delete unless all_removals.empty?
              end

              def persist_dirty_associations(db, associations_snapshot, scoped_trace_ids, memory_trace_ids, stale_ids, dirty)
                assoc_scope_ids = (scoped_trace_ids + memory_trace_ids).uniq
                return unless (dirty || !stale_ids.empty?) && !assoc_scope_ids.empty?

                association_columns = db[:memory_associations].columns
                partitioned_associations = association_columns.include?(:partition_id)
                if partitioned_associations
                  db[:memory_associations].where(partition_id: @partition_id).delete
                else
                  assoc_scope_ids.each_slice(ASSOCIATION_LOAD_BATCH_SIZE) do |ids|
                    db[:memory_associations].where(trace_id_a: ids).delete
                    db[:memory_associations].where(trace_id_b: ids).delete
                  end
                end

                associations_snapshot.each do |id_a, targets|
                  targets.each do |id_b, count|
                    row = { trace_id_a: id_a, trace_id_b: id_b, coactivation_count: count }
                    row[:partition_id] = @partition_id if partitioned_associations
                    db[:memory_associations].insert(row)
                  end
                end
              end

              def clear_dirty_flags(trace_rows_snapshot)
                @mutex.synchronize do
                  @dirty_trace_ids.clear
                  @deleted_trace_ids.clear
                  @associations_dirty = false
                  @persisted_trace_rows = trace_rows_snapshot
                end
              end

              def load_from_local
                return unless defined?(Legion::Data::Local) && Legion::Data::Local.connected?
                return unless Legion::Data::Local.connection.table_exists?(:memory_traces)

                db = Legion::Data::Local.connection

                db[:memory_traces].where(partition_id: @partition_id).each do |row|
                  @traces[row[:trace_id]] = deserialize_trace_from_db(row)
                  @persisted_trace_rows[row[:trace_id]] = row.dup
                end

                load_local_associations(db)

                @dirty_trace_ids = Set.new
                @deleted_trace_ids = Set.new
                @associations_dirty = false
              end

              private

              def load_local_associations(db)
                association_columns = db[:memory_associations].columns
                if association_columns.include?(:partition_id)
                  db[:memory_associations].where(partition_id: @partition_id).each { |row| load_association_row(row) }
                else
                  @traces.keys.each_slice(ASSOCIATION_LOAD_BATCH_SIZE) do |trace_ids|
                    db[:memory_associations].where(trace_id_a: trace_ids).each { |row| load_association_row(row) }
                  end
                end
              end

              def load_association_row(row)
                return unless @traces.key?(row[:trace_id_a])

                @associations[row[:trace_id_a]] ||= {}
                @associations[row[:trace_id_a]][row[:trace_id_b]] = row[:coactivation_count]
              end

              def resolve_partition_id
                Legion::Settings.dig(:agent, :id) || 'default'
              rescue StandardError => e
                log.error "[trace_persistence] resolve_partition_id: #{e.message}"
                'default'
              end

              def serialize_trace_for_db(trace)
                payload = trace[:content_payload] || trace[:content]
                content = payload.is_a?(Hash) ? ::JSON.generate(payload) : payload.to_s
                content = content.dup.force_encoding('BINARY').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
                                 .delete("\0")
                {
                  trace_id:                trace[:trace_id],
                  trace_type:              trace[:trace_type].to_s,
                  content:                 content,
                  strength:                trace[:strength],
                  peak_strength:           trace[:peak_strength],
                  base_decay_rate:         trace[:base_decay_rate],
                  emotional_valence:       Helpers::Trace.normalize_emotional_valence(trace[:emotional_valence]).to_s,
                  emotional_intensity:     trace[:emotional_intensity],
                  domain_tags:             trace[:domain_tags].is_a?(Array) ? ::JSON.generate(trace[:domain_tags]) : nil,
                  origin:                  trace[:origin].to_s,
                  created_at:              trace[:created_at],
                  last_reinforced:         trace[:last_reinforced],
                  last_decayed:            trace[:last_decayed],
                  reinforcement_count:     trace[:reinforcement_count],
                  confidence:              trace[:confidence],
                  storage_tier:            trace[:storage_tier].to_s,
                  partition_id:            trace[:partition_id],
                  associated_traces:       trace[:associated_traces].is_a?(Array) ? ::JSON.generate(trace[:associated_traces]) : nil,
                  parent_id:               trace[:parent_trace_id] || trace[:parent_id],
                  child_ids:               (trace[:child_trace_ids] || trace[:child_ids]).then do |v|
                                             v.is_a?(Array) ? ::JSON.generate(v) : nil
                                           end,
                  unresolved:              trace[:unresolved] || false,
                  consolidation_candidate: trace[:consolidation_candidate] || false
                }
              end

              def deserialize_trace_from_db(row)
                content = parse_db_content(row[:content])
                {
                  trace_id:                row[:trace_id],
                  trace_type:              row[:trace_type]&.to_sym,
                  content_payload:         content,
                  content:                 content,
                  strength:                row[:strength],
                  peak_strength:           row[:peak_strength],
                  base_decay_rate:         row[:base_decay_rate],
                  emotional_valence:       deserialize_emotional_valence(row[:emotional_valence]),
                  emotional_intensity:     row[:emotional_intensity],
                  domain_tags:             parse_db_json(row[:domain_tags], 'domain_tags') { [] },
                  origin:                  row[:origin]&.to_sym,
                  created_at:              row[:created_at],
                  last_reinforced:         row[:last_reinforced],
                  last_decayed:            row[:last_decayed],
                  reinforcement_count:     row[:reinforcement_count],
                  confidence:              row[:confidence],
                  storage_tier:            row[:storage_tier]&.to_sym,
                  partition_id:            row[:partition_id],
                  associated_traces:       parse_db_json(row[:associated_traces], 'associated_traces') { [] },
                  parent_trace_id:         row[:parent_id],
                  child_trace_ids:         parse_db_json(row[:child_ids], 'child_ids') { [] },
                  unresolved:              row[:unresolved] || false,
                  consolidation_candidate: row[:consolidation_candidate] || false
                }
              end

              def parse_db_content(raw)
                return raw unless raw.is_a?(String)

                stripped = raw.strip
                return raw unless parseable_content_json?(stripped)

                parsed = Legion::JSON.load(stripped)
                parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : raw
              rescue StandardError => _e
                raw
              end

              def parseable_content_json?(value)
                return true if value.start_with?('{')
                return false unless value.start_with?('[')

                first_array_value = value[1..]&.lstrip&.[](0)
                %w[{ [ " ]].include?(first_array_value)
              end

              def deserialize_emotional_valence(raw)
                return 0.0 if raw.nil? || raw.to_s.strip.empty?

                Helpers::Trace.normalize_emotional_valence(raw)
              end

              def parse_db_json(raw, field, symbolize: false, &default)
                return default&.call if raw.nil? || raw.to_s.strip.empty?

                parsed = Legion::JSON.load(raw.to_s)
                symbolize ? symbolize_keys(parsed) : parsed
              rescue StandardError => e
                log.error "[trace_persistence] deserialize_trace_from_db #{field}: #{e.message}"
                default&.call
              end

              def symbolize_keys(value)
                case value
                when Hash
                  value.each_with_object({}) do |(key, nested), memo|
                    memo[key.to_sym] = symbolize_keys(nested)
                  end
                when Array
                  value.map { |nested| symbolize_keys(nested) }
                else
                  value
                end
              end

              def link_traces(id_a, id_b)
                trace_a = @traces[id_a]
                trace_b = @traces[id_b]
                return unless trace_a && trace_b

                max = Helpers::Trace::MAX_ASSOCIATIONS
                changed = false

                unless trace_a[:associated_traces].include?(id_b) || trace_a[:associated_traces].size >= max
                  trace_a[:associated_traces] << id_b
                  changed = true
                end

                unless trace_b[:associated_traces].include?(id_a) || trace_b[:associated_traces].size >= max
                  trace_b[:associated_traces] << id_a
                  changed = true
                end

                changed
              end
            end
          end
        end
      end
    end
  end
end
