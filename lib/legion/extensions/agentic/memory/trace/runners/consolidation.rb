# frozen_string_literal: true

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          module Runners
            module Consolidation
              def reinforce(trace_id:, store: nil, imprint_active: false, **)
                store ||= default_store
                trace = store.get(trace_id)
                return { found: false } unless trace
                return { found: true, reinforced: false, reason: :firmware } if trace[:trace_type] == :firmware

                new_strength = Helpers::Decay.compute_reinforcement(
                  current_strength: trace[:strength], imprint_active: imprint_active
                )

                now = Time.now.utc
                trace[:strength] = new_strength
                trace[:peak_strength] = [trace[:peak_strength], new_strength].max
                trace[:last_reinforced] = now
                trace[:reinforcement_count] += 1

                store.store(trace)
                persist_store(store)

                log.debug("[memory] reinforced #{trace_id[0..7]} strength=#{new_strength.round(3)}#{' (imprint 3x)' if imprint_active}")
                { found: true, reinforced: true, trace_id: trace_id, new_strength: new_strength }
              end

              def decay_cycle(store: nil, tick_count: nil, maintenance: true, **)
                unless maintenance
                  deferred = deferred_decay_summary(store || cached_default_store)
                  return { **deferred }
                end

                store ||= default_store
                decayed = 0
                pruned = 0
                total = trace_count(store)
                now = Time.now.utc

                store.all_traces.each do |trace|
                  next if trace[:base_decay_rate].zero?

                  # Explicit tick_count is an age override; actor maintenance derives age from persisted access time.
                  ticks_since_access = tick_count || [(now - Helpers::Decay.ensure_time(trace[:last_reinforced])) /
                    Helpers::Decay::TICK_INTERVAL, 0].max

                  new_strength = Helpers::Decay.compute_decay(
                    peak_strength:       trace[:peak_strength],
                    base_decay_rate:     trace[:base_decay_rate],
                    ticks_since_access:  ticks_since_access,
                    emotional_intensity: trace[:emotional_intensity]
                  )
                  new_strength = [trace[:strength], new_strength].min

                  if new_strength <= Helpers::Trace::PRUNE_THRESHOLD
                    store.delete(trace[:trace_id])
                    pruned += 1
                  else
                    trace[:strength] = new_strength
                    trace[:last_decayed] = now
                    store.store(trace)
                    decayed += 1
                  end
                end

                persist_store(store) if decayed.positive? || pruned.positive?

                remaining = trace_count(store)
                summary = {
                  decayed:       decayed,
                  pruned:        pruned,
                  total:         total,
                  remaining:     remaining,
                  maintained_at: now
                }
                Legion::Extensions::Agentic::Memory::Trace.record_maintenance_summary(summary.dup)

                log.debug("[memory] decay cycle: decayed=#{decayed} pruned=#{pruned}")
                summary
              end

              def migrate_tier(store: nil, **)
                store ||= default_store
                migrated = 0
                now = Time.now.utc

                store.all_traces.each do |trace|
                  new_tier = Helpers::Decay.compute_storage_tier(trace: trace, now: now)
                  next if trace[:storage_tier] == new_tier

                  trace[:storage_tier] = new_tier
                  store.store(trace)
                  migrated += 1
                end

                persist_store(store) if migrated.positive?
                log.debug("[memory] tier migration: migrated=#{migrated}")
                { migrated: migrated }
              end

              def hebbian_link(trace_id_a: nil, trace_id_b: nil, store: nil, **)
                return { linked: false, reason: :missing_trace_ids } if trace_id_a.nil? || trace_id_b.nil?

                store ||= default_store
                store.record_coactivation(trace_id_a, trace_id_b)
                persist_store(store)
                log.debug("[memory] hebbian link #{trace_id_a[0..7]} <-> #{trace_id_b[0..7]}")
                { linked: true }
              end

              def enforce_quota(store: nil, **)
                store ||= default_store
                quota = Quota.new
                quota.enforce!(store)
                { success: true, within_limits: quota.within_limits?(store) }
              end

              def erase_by_type(type:, store: nil, **)
                store ||= default_store
                type = type.to_sym

                count = if store.respond_to?(:batch_delete_by_type)
                          store.batch_delete_by_type(type)
                        else
                          traces = store.retrieve_by_type(type, min_strength: 0.0, limit: 100_000)
                          traces.each { |t| store.delete(t[:trace_id]) }
                          traces.size
                        end

                persist_store(store) if count.positive?
                log.info("[memory] erased #{count} traces of type=#{type}")
                { erased: count, type: type }
              end

              def erase_by_agent(partition_id:, store: nil, **)
                store ||= default_store
                traces = store.all_traces.select { |t| t[:partition_id] == partition_id }
                count = traces.size
                traces.each { |t| store.delete(t[:trace_id]) }
                persist_store(store) if count.positive?
                log.info("[memory] erased #{count} traces for partition=#{partition_id}")
                { erased: count, partition_id: partition_id }
              end

              private

              def deferred_decay_summary(store)
                summary = Legion::Extensions::Agentic::Memory::Trace.last_maintenance_summary || {}
                current_count = store ? trace_count(store) : 0

                {
                  decayed:       summary[:decayed] || 0,
                  pruned:        summary[:pruned] || 0,
                  total:         summary[:total] || current_count,
                  remaining:     summary[:remaining] || current_count,
                  maintained_at: summary[:maintained_at],
                  deferred:      true,
                  reason:        :background_decay_actor
                }
              end

              def trace_count(store)
                if store.respond_to?(:count)
                  store.count
                else
                  store.all_traces.size
                end
              rescue StandardError => e
                log.debug("[memory] trace_count fallback: #{e.message}")
                store.all_traces.size
              end

              def persist_store(store)
                store.flush if store.respond_to?(:flush)
              rescue StandardError => e
                log.debug("[memory] persist_store skipped: #{e.message}")
              end

              def default_store
                @default_store ||= Legion::Extensions::Agentic::Memory::Trace.shared_store
              end

              def cached_default_store
                @default_store if instance_variable_defined?(:@default_store)
              end

              include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
            end
          end
        end
      end
    end
  end
end
