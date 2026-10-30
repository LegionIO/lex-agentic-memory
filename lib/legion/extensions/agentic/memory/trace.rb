# frozen_string_literal: true

require 'legion/extensions/agentic/memory/trace/version'
require 'legion/extensions/agentic/memory/trace/helpers/trace'
require 'legion/extensions/agentic/memory/trace/helpers/decay'
require 'legion/extensions/agentic/memory/trace/helpers/store'
require 'legion/extensions/agentic/memory/trace/helpers/cache_store'
require 'legion/extensions/agentic/memory/trace/helpers/postgres_store'
require 'legion/extensions/agentic/memory/trace/helpers/error_tracer'
require 'legion/extensions/agentic/memory/trace/runners/traces'
require 'legion/extensions/agentic/memory/trace/runners/consolidation'
require 'legion/extensions/agentic/memory/trace/client'

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          class << self
            # Process-wide default trace store. All memory runners delegate here so
            # traces written by one component remain visible to the rest of the
            # current agent runtime. Raw trace storage prefers agent-local durable
            # state and only falls back to shared stores when explicitly requested
            # or when local persistence is unavailable.
            def shared_store
              @shared_store ||= create_store
            end

            def last_maintenance_summary
              @maintenance_summary
            end

            def record_maintenance_summary(summary)
              @maintenance_summary = summary
            end

            def reset_store!
              @shared_store = nil
              @maintenance_summary = nil
            end

            private

            def create_store
              if local_store_available? && configured_trace_store != :shared
                Legion::Logging.debug '[memory] Using agent-local Store (Data::Local-backed)'
                Helpers::Store.new(partition_id: resolve_agent_id)
              elsif postgres_available?
                Legion::Logging.debug '[memory] Using shared PostgresStore (write-through)'
                Helpers::PostgresStore.new(tenant_id: resolve_tenant_id, agent_id: resolve_agent_id)
              elsif defined?(Legion::Cache) && Legion::Cache.respond_to?(:connected?) && Legion::Cache.connected?
                Legion::Logging.debug '[memory] Using shared CacheStore (memcached)'
                Helpers::CacheStore.new(partition_id: resolve_agent_id)
              else
                Legion::Logging.debug '[memory] Using agent-local in-memory Store'
                Helpers::Store.new(partition_id: resolve_agent_id)
              end
            end

            def configured_trace_store
              Legion::Settings.dig(:memory, :trace_store)&.to_sym
            rescue StandardError => _e
              nil
            end

            def local_store_available?
              defined?(Legion::Data::Local) &&
                Legion::Data::Local.respond_to?(:connected?) &&
                Legion::Data::Local.connected? &&
                Legion::Data::Local.connection&.table_exists?(:memory_traces) &&
                Legion::Data::Local.connection.table_exists?(:memory_associations)
            rescue StandardError => _e
              false
            end

            def postgres_available?
              defined?(Legion::Data) &&
                Legion::Data.respond_to?(:connection) &&
                Legion::Data.connection &&
                %i[postgres mysql2].include?(Legion::Data.connection.adapter_scheme) &&
                Legion::Data.connection.table_exists?(:memory_traces) &&
                Legion::Data.connection.table_exists?(:memory_associations) &&
                Legion::Data.can_write?(:memory_traces) &&
                Legion::Data.can_write?(:memory_associations)
            rescue StandardError => _e
              false
            end

            def resolve_tenant_id
              Legion::Settings[:data]&.dig(:tenant_id)
            rescue StandardError => _e
              nil
            end

            def resolve_agent_id
              Legion::Settings.dig(:agent, :id) || 'default'
            rescue StandardError => _e
              'default'
            end
          end
        end
      end
    end

    if defined?(Legion::Data::Local)
      Legion::Data::Local.register_migrations(
        name: :memory,
        path: File.join(__dir__, 'trace', 'local_migrations')
      )
    end
  end
end
