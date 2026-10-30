# frozen_string_literal: true

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          module Runners
            module Traces
              def store_trace(type:, content_payload:, store: nil, **)
                store ||= default_store
                trace = Helpers::Trace.new_trace(type: type.to_sym, content_payload: content_payload, **)
                store.store(trace)
                persist_store(store)
                log.debug("[memory] stored trace #{trace[:trace_id][0..7]} type=#{trace[:trace_type]} strength=#{trace[:strength].round(2)}")
                { trace_id: trace[:trace_id], trace_type: trace[:trace_type], strength: trace[:strength] }
              end

              def get_trace(trace_id:, store: nil, **)
                store ||= default_store
                trace = store.get(trace_id)
                log.debug("[memory] get trace #{trace_id[0..7]} found=#{!trace.nil?}")
                return { found: false } unless trace

                { found: true, trace: trace }
              end

              def retrieve_by_type(type:, store: nil, min_strength: 0.0, limit: 100, **)
                store ||= default_store
                traces = store.retrieve_by_type(type.to_sym, min_strength: min_strength, limit: limit)
                log.debug("[memory] retrieve_by_type=#{type} count=#{traces.size} min_strength=#{min_strength}")
                { count: traces.size, traces: traces }
              end

              def retrieve_by_domain(domain_tag:, store: nil, min_strength: 0.0, limit: 100, **)
                store ||= default_store
                traces = store.retrieve_by_domain(domain_tag, min_strength: min_strength, limit: limit)
                log.debug("[memory] retrieve_by_domain=#{domain_tag} count=#{traces.size}")
                { count: traces.size, traces: traces }
              end

              def retrieve_associated(trace_id:, store: nil, min_strength: 0.0, limit: 20, **)
                store ||= default_store
                traces = store.retrieve_associated(trace_id, min_strength: min_strength, limit: limit)
                log.debug("[memory] retrieve_associated for #{trace_id[0..7]} count=#{traces.size}")
                { count: traces.size, traces: traces }
              end

              def retrieve_ranked(trace_ids: [], store: nil, query_time: nil, domain_tag: nil, **scope)
                store ||= default_store
                query_time ||= Time.now.utc
                associated_set = Set.new

                traces = trace_ids.uniq.filter_map { |id| store.get(id) }
                traces = filter_trace_candidates(traces: traces, domain_tag: domain_tag, **scope)
                traces.each { |t| associated_set.merge(t[:associated_traces]) }

                scored = traces.map do |t|
                  score = Helpers::Decay.compute_retrieval_score(
                    trace: t, query_time: query_time, associated: associated_set.include?(t[:trace_id])
                  )
                  { trace: t, score: score }
                end

                result = scored.sort_by { |s| -s[:score] }
                log.debug("[memory] retrieve_ranked ids=#{trace_ids.size} scored=#{result.size}")
                { success: true, traces: result }
              end

              def delete_trace(trace_id:, store: nil, **)
                store ||= default_store
                store.delete(trace_id)
                persist_store(store)
                log.debug("[memory] deleted trace #{trace_id[0..7]}")
                { deleted: true, trace_id: trace_id }
              end

              def erase_partner!(identity:, store: nil, **)
                store ||= default_store
                partner_result = store.retrieve_by_domain("partner:#{identity}", min_strength: 0.0, limit: 10_000)
                owner_result   = store.retrieve_by_domain("owner:#{identity}",   min_strength: 0.0, limit: 10_000)
                traces_to_erase = Array(partner_result) + Array(owner_result)

                traces_to_erase.each { |t| store.delete(t[:trace_id]) }
                persist_store(store) unless traces_to_erase.empty?

                count = traces_to_erase.size
                log.info("[memory] erase_partner! identity=#{identity} erased=#{count}")
                { erased: true, identity: identity, count: count }
              end

              def retrieve_and_reinforce(limit: 10, store: nil, trace_ids: nil, domain_tag: nil, **scope)
                store ||= default_store
                candidates = if trace_ids
                               trace_ids.uniq.filter_map { |id| store.get(id) }.select { |trace| trace[:strength] >= 0.1 }
                             else
                               store.all_traces(min_strength: 0.1)
                             end
                candidates = filter_trace_candidates(traces: candidates, domain_tag: domain_tag, **scope)
                top = candidates.sort_by { |trace| -trace[:strength] }.first(limit)

                top.each do |trace|
                  next if trace[:base_decay_rate].zero? # skip firmware

                  trace[:reinforcement_count] += 1
                  trace[:last_reinforced] = Time.now.utc
                  store.store(trace)
                end

                persist_store(store) unless top.empty?

                log.debug("[memory] retrieve_and_reinforce: retrieved=#{top.size} from=#{candidates.size} candidates")
                { count: top.size, traces: top }
              end

              private

              def filter_trace_candidates(traces:, domain_tag:, **scope)
                return traces unless domain_tag || scope.key?(:identity) # rubocop:disable Legion/Extension/RunnerReturnHash -- Private helper returns candidate arrays.

                traces.select do |trace|
                  tags = Array(trace[:domain_tags])
                  next false if domain_tag && !tags.include?(domain_tag)
                  next true unless scope.key?(:identity)

                  identity = scope[:identity].to_s
                  tags.all? do |tag|
                    tag = tag.to_s
                    next true unless tag.start_with?('partner:', 'owner:')

                    !identity.strip.empty? && ["partner:#{identity}", "owner:#{identity}"].include?(tag)
                  end
                end
              end

              def persist_store(store)
                store.flush if store.respond_to?(:flush)
              rescue StandardError => e
                log.debug("[memory] persist_store skipped: #{e.message}")
              end

              def default_store
                @default_store ||= Legion::Extensions::Agentic::Memory::Trace.shared_store
              end

              include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
            end
          end
        end
      end
    end
  end
end
