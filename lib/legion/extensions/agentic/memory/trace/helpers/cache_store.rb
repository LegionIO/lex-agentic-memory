# frozen_string_literal: true

require 'legion/logging'
require 'legion/cache/helper'

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          module Helpers
            # Cache-backed store using Legion::Cache (Memcached/Redis).
            # Each trace is stored as an individual cache key for scalability.
            # An index key tracks all known trace IDs.
            # Keeps a local in-memory copy for fast reads; syncs to cache on flush.
            class CacheStore
              include Legion::Logging::Helper if defined?(Legion::Logging::Helper)
              include Legion::Cache::Helper if defined?(Legion::Cache::Helper)

              TTL          = 86_400 # 24 hours
              FLUSH_BATCH  = 500    # traces per flush batch

              attr_reader :traces, :associations

              def initialize(partition_id: nil)
                log.info('[memory] CacheStore initialized (memcached-backed, per-key)')
                @mutex        = Mutex.new
                @traces       = {}
                @associations = {}
                @dirty_ids    = Set.new
                @deleted_ids  = Set.new
                @assoc_dirty  = false
                @partition_id = partition_id || Helpers::Trace.default_partition_id
                # Global legacy cache keys cannot establish agent ownership and must not be hydrated.
                @cache_prefix = "legion:memory:partition:#{@partition_id}:"
                load_index
                log.info("[memory] CacheStore loaded #{@traces.size} traces from cache")
              end

              def store(trace)
                normalized_trace = Helpers::Trace.normalize_trace_affect(trace)
                normalized_trace[:partition_id] ||= @partition_id
                @mutex.synchronize do
                  @traces[normalized_trace[:trace_id]] = normalized_trace
                  @dirty_ids << normalized_trace[:trace_id]
                end
                normalized_trace[:trace_id]
              end

              def get(trace_id)
                @traces[trace_id]
              end

              def delete(trace_id)
                @mutex.synchronize do
                  @traces.delete(trace_id)
                  @traces.each_value do |trace|
                    @dirty_ids << trace[:trace_id] if trace[:associated_traces]&.delete(trace_id)
                  end
                  @associations.delete(trace_id)
                  @associations.each_value { |links| links.delete(trace_id) }
                  @dirty_ids.delete(trace_id)
                  @deleted_ids << trace_id
                  @assoc_dirty = true
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
                trace = @traces[trace_id]
                return [] unless trace

                trace[:associated_traces]
                  .filter_map { |id| @traces[id] }
                  .select { |t| t[:strength] >= min_strength }
                  .sort_by { |t| -t[:strength] }
                  .first(limit)
              end

              def record_coactivation(trace_id_a, trace_id_b)
                return if trace_id_a == trace_id_b

                @mutex.synchronize do
                  @associations[trace_id_a] ||= {}
                  @associations[trace_id_b] ||= {}
                  @associations[trace_id_a][trace_id_b] = (@associations[trace_id_a][trace_id_b] || 0) + 1
                  @associations[trace_id_b][trace_id_a] = (@associations[trace_id_b][trace_id_a] || 0) + 1

                  threshold = Helpers::Trace::COACTIVATION_THRESHOLD
                  if @associations[trace_id_a][trace_id_b] >= threshold && link_traces(trace_id_a, trace_id_b)
                    @dirty_ids << trace_id_a
                    @dirty_ids << trace_id_b
                  end
                  @assoc_dirty = true
                end
              end

              def all_traces(min_strength: 0.0)
                snapshot = @mutex.synchronize { @traces.values }
                snapshot.select { |t| t[:strength] >= min_strength }
              end

              def count
                @traces.size
              end

              def synchronize(&) = @mutex.synchronize(&)

              def firmware_traces
                retrieve_by_type(:firmware)
              end

              def walk_associations(start_id:, max_hops: 12, min_strength: 0.1)
                snapshot = @mutex.synchronize { @traces.dup }
                return [] unless snapshot.key?(start_id)

                results = []
                visited = Set.new([start_id])
                queue   = [[start_id, 0, [start_id]]]

                until queue.empty?
                  current_id, depth, path = queue.shift
                  current = snapshot[current_id]
                  next unless current

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

              # Write dirty traces to cache as individual keys
              def flush
                @mutex.synchronize do
                  flush_deleted
                  flush_traces
                  flush_associations
                  flush_index
                  log.debug("[memory] CacheStore flushed #{@dirty_ids.size} dirty traces (#{@traces.size} total)")
                  @dirty_ids.clear
                  @deleted_ids.clear
                end
              end

              # Pull latest state from cache
              def reload
                @traces.clear
                @associations = {}
                @dirty_ids.clear
                @deleted_ids.clear
                @assoc_dirty = false
                load_index
                log.debug("[memory] CacheStore reloaded #{@traces.size} traces from cache")
              end

              private

              def trace_key(trace_id)
                "#{@cache_prefix}trace:#{trace_id}"
              end

              def load_index
                legacy_index = cache_get('legion:memory:trace_index')
                if legacy_index.is_a?(Array) && !legacy_index.empty?
                  log.warn('[memory] Ignoring legacy global cache history: agent ownership is ambiguous; legacy keys remain untouched')
                end

                index = cache_get("#{@cache_prefix}index")
                return unless index.is_a?(Array)

                loaded = 0
                index.each do |id|
                  trace = cache_get(trace_key(id))
                  if trace
                    @traces[id] = trace
                    loaded += 1
                  end
                end
                associations = cache_get("#{@cache_prefix}associations")
                if associations.is_a?(Hash)
                  @associations = associations.each_with_object({}) do |(id, links), restored|
                    next unless @traces.key?(id)

                    restored[id] = links.select { |target, _count| @traces.key?(target) }
                  end
                end
                log.debug("[memory] CacheStore loaded #{loaded}/#{index.size} traces from index")
              rescue StandardError => e
                log.warn("[memory] CacheStore load_index failed: #{e.message}")
              end

              def flush_traces
                return if @dirty_ids.empty?

                @dirty_ids.each_slice(FLUSH_BATCH) do |batch|
                  batch.each do |id|
                    trace = @traces[id]
                    cache_set(trace_key(id), trace, ttl: TTL) if trace
                  end
                end
              end

              def flush_deleted
                @deleted_ids.each do |id|
                  cache_delete(trace_key(id))
                end
              end

              def flush_associations
                return unless @assoc_dirty

                cache_set("#{@cache_prefix}associations", strip_default_procs(@associations), ttl: TTL)
                @assoc_dirty = false
              rescue StandardError => e
                log.warn("[memory] CacheStore flush_associations failed (#{@associations.size} entries): #{e.message}")
              end

              def flush_index
                return if @dirty_ids.empty? && @deleted_ids.empty?

                cache_set("#{@cache_prefix}index", @traces.keys, ttl: TTL)
              rescue StandardError => e
                log.warn("[memory] CacheStore flush_index failed (#{@traces.size} traces): #{e.message}")
              end

              def strip_default_procs(hash)
                hash.each_with_object({}) do |(k, v), plain|
                  plain[k] = v.is_a?(Hash) ? {}.merge(v) : v
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
