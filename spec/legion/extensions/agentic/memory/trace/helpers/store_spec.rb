# frozen_string_literal: true

require 'sequel'

RSpec.describe Legion::Extensions::Agentic::Memory::Trace::Helpers::Store do
  let(:store) { described_class.new }
  let(:trace_helper) { Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace }

  let(:semantic_trace) { trace_helper.new_trace(type: :semantic, content_payload: { fact: 'ruby is great' }, domain_tags: ['programming']) }
  let(:episodic_trace) { trace_helper.new_trace(type: :episodic, content_payload: { event: 'meeting' }, domain_tags: ['work']) }
  let(:firmware_trace) { trace_helper.new_trace(type: :firmware, content_payload: { directive_text: 'protect' }) }

  describe '#store and #get' do
    it 'stores and retrieves a trace' do
      store.store(semantic_trace)
      result = store.get(semantic_trace[:trace_id])
      expect(result[:trace_type]).to eq(:semantic)
    end

    it 'assigns the store partition_id when a trace does not already have one' do
      semantic_trace[:partition_id] = nil

      store.store(semantic_trace)
      result = store.get(semantic_trace[:trace_id])
      expect(result[:partition_id]).to eq('default')
    end

    it 'returns nil for unknown trace_id' do
      expect(store.get('nonexistent')).to be_nil
    end
  end

  describe '#delete' do
    it 'removes a trace' do
      store.store(semantic_trace)
      store.delete(semantic_trace[:trace_id])
      expect(store.get(semantic_trace[:trace_id])).to be_nil
    end
  end

  describe '#retrieve_by_type' do
    it 'returns traces of specified type' do
      store.store(semantic_trace)
      store.store(episodic_trace)

      results = store.retrieve_by_type(:semantic)
      expect(results.size).to eq(1)
      expect(results.first[:trace_type]).to eq(:semantic)
    end

    it 'filters by min_strength' do
      weak_trace = trace_helper.new_trace(type: :semantic, content_payload: {})
      weak_trace[:strength] = 0.1
      store.store(weak_trace)
      store.store(semantic_trace)

      results = store.retrieve_by_type(:semantic, min_strength: 0.4)
      expect(results.size).to eq(1)
    end

    it 'respects limit' do
      3.times { store.store(trace_helper.new_trace(type: :semantic, content_payload: {})) }
      results = store.retrieve_by_type(:semantic, limit: 2)
      expect(results.size).to eq(2)
    end
  end

  describe '#retrieve_by_domain' do
    it 'returns traces matching domain tag' do
      store.store(semantic_trace)
      store.store(episodic_trace)

      results = store.retrieve_by_domain('programming')
      expect(results.size).to eq(1)
    end
  end

  describe '#record_coactivation and #retrieve_associated' do
    it 'links traces after reaching coactivation threshold' do
      store.store(semantic_trace)
      store.store(episodic_trace)

      threshold = Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace::COACTIVATION_THRESHOLD
      threshold.times { store.record_coactivation(semantic_trace[:trace_id], episodic_trace[:trace_id]) }

      associated = store.retrieve_associated(semantic_trace[:trace_id])
      expect(associated.size).to eq(1)
      expect(associated.first[:trace_id]).to eq(episodic_trace[:trace_id])
    end

    it 'does not link before threshold' do
      store.store(semantic_trace)
      store.store(episodic_trace)

      store.record_coactivation(semantic_trace[:trace_id], episodic_trace[:trace_id])

      associated = store.retrieve_associated(semantic_trace[:trace_id])
      expect(associated.size).to eq(0)
    end

    it 'snapshots associated traces while holding the store mutex' do
      store.store(semantic_trace)
      store.store(episodic_trace)
      semantic_trace[:associated_traces] << episodic_trace[:trace_id]

      mutex = store.instance_variable_get(:@mutex)
      expect(mutex).to receive(:synchronize).and_call_original

      associated = store.retrieve_associated(semantic_trace[:trace_id])
      expect(associated.map { |trace| trace[:trace_id] }).to eq([episodic_trace[:trace_id]])
    end
  end

  describe '#all_traces' do
    it 'returns all stored traces' do
      store.store(semantic_trace)
      store.store(episodic_trace)
      expect(store.all_traces.size).to eq(2)
    end

    it 'filters by min_strength' do
      weak = trace_helper.new_trace(type: :semantic, content_payload: {})
      weak[:strength] = 0.01
      store.store(weak)
      store.store(semantic_trace)

      expect(store.all_traces(min_strength: 0.1).size).to eq(1)
    end
  end

  describe '#parse_db_content' do
    let(:parser) { described_class.allocate }

    it 'returns bracket-prefixed raw log text without logging malformed JSON noise' do
      expect(parser).not_to receive(:log)

      result = parser.send(:parse_db_content, '[tool][file_read] opened file')

      expect(result).to eq('[tool][file_read] opened file')
    end

    it 'still parses JSON object content' do
      result = parser.send(:parse_db_content, '{"event":"meeting"}')

      expect(result).to eq({ event: 'meeting' })
    end

    it 'still parses JSON array content when it looks like serialized payload data' do
      result = parser.send(:parse_db_content, '[{"event":"meeting"}]')

      expect(result).to eq([{ event: 'meeting' }])
    end
  end

  describe '#count' do
    it 'returns number of stored traces' do
      expect(store.count).to eq(0)
      store.store(semantic_trace)
      expect(store.count).to eq(1)
    end
  end

  describe '#firmware_traces' do
    it 'returns only firmware traces' do
      store.store(firmware_trace)
      store.store(semantic_trace)

      results = store.firmware_traces
      expect(results.size).to eq(1)
      expect(results.first[:trace_type]).to eq(:firmware)
    end
  end

  describe '#walk_associations' do
    let(:trace_a) { trace_helper.new_trace(type: :semantic, content_payload: { label: 'a' }) }
    let(:trace_b) { trace_helper.new_trace(type: :semantic, content_payload: { label: 'b' }) }
    let(:trace_c) { trace_helper.new_trace(type: :semantic, content_payload: { label: 'c' }) }
    let(:trace_d) { trace_helper.new_trace(type: :semantic, content_payload: { label: 'd' }) }

    before do
      store.store(trace_a)
      store.store(trace_b)
      store.store(trace_c)
      store.store(trace_d)
      # Chain: a -> b -> c -> d
      trace_a[:associated_traces] << trace_b[:trace_id]
      trace_b[:associated_traces] << trace_a[:trace_id]
      trace_b[:associated_traces] << trace_c[:trace_id]
      trace_c[:associated_traces] << trace_b[:trace_id]
      trace_c[:associated_traces] << trace_d[:trace_id]
      trace_d[:associated_traces] << trace_c[:trace_id]
    end

    it 'walks multiple hops from start trace' do
      results = store.walk_associations(start_id: trace_a[:trace_id])
      found_ids = results.map { |r| r[:trace_id] }
      expect(found_ids).to include(trace_b[:trace_id], trace_c[:trace_id], trace_d[:trace_id])
    end

    it 'respects max_hops limit' do
      results = store.walk_associations(start_id: trace_a[:trace_id], max_hops: 1)
      found_ids = results.map { |r| r[:trace_id] }
      expect(found_ids).to include(trace_b[:trace_id])
      expect(found_ids).not_to include(trace_c[:trace_id])
      expect(found_ids).not_to include(trace_d[:trace_id])
    end

    it 'does not include start trace in results' do
      results = store.walk_associations(start_id: trace_a[:trace_id])
      found_ids = results.map { |r| r[:trace_id] }
      expect(found_ids).not_to include(trace_a[:trace_id])
    end

    it 'handles cycles without infinite loop' do
      # Add a back-edge from d to a to create a cycle
      trace_d[:associated_traces] << trace_a[:trace_id]
      trace_a[:associated_traces] << trace_d[:trace_id]
      expect { store.walk_associations(start_id: trace_a[:trace_id]) }.not_to raise_error
      results = store.walk_associations(start_id: trace_a[:trace_id])
      found_ids = results.map { |r| r[:trace_id] }
      expect(found_ids.uniq.size).to eq(found_ids.size)
    end

    it 'records depth for each discovered trace' do
      results = store.walk_associations(start_id: trace_a[:trace_id])
      b_result = results.find { |r| r[:trace_id] == trace_b[:trace_id] }
      c_result = results.find { |r| r[:trace_id] == trace_c[:trace_id] }
      d_result = results.find { |r| r[:trace_id] == trace_d[:trace_id] }
      expect(b_result[:depth]).to eq(1)
      expect(c_result[:depth]).to eq(2)
      expect(d_result[:depth]).to eq(3)
    end

    it 'records the full path to each discovered trace' do
      results = store.walk_associations(start_id: trace_a[:trace_id])
      d_result = results.find { |r| r[:trace_id] == trace_d[:trace_id] }
      expect(d_result[:path].first).to eq(trace_a[:trace_id])
      expect(d_result[:path].last).to eq(trace_d[:trace_id])
      expect(d_result[:path].size).to eq(4)
    end

    it 'filters by min_strength and does not traverse beyond filtered nodes' do
      store.traces[trace_b[:trace_id]][:strength] = 0.05
      results = store.walk_associations(start_id: trace_a[:trace_id], min_strength: 0.1)
      found_ids = results.map { |r| r[:trace_id] }
      expect(found_ids).not_to include(trace_b[:trace_id])
      expect(found_ids).not_to include(trace_c[:trace_id])
      expect(found_ids).not_to include(trace_d[:trace_id])
    end

    it 'returns empty array for trace with no associations' do
      lone = trace_helper.new_trace(type: :semantic, content_payload: { label: 'lone' })
      store.store(lone)
      results = store.walk_associations(start_id: lone[:trace_id])
      expect(results).to eq([])
    end

    it 'returns empty array for unknown start_id' do
      results = store.walk_associations(start_id: 'nonexistent-id')
      expect(results).to eq([])
    end
  end

  describe 'local persistence' do
    let(:local_db) do
      d = Sequel.sqlite
      d.create_table(:memory_traces) do
        primary_key :id
        String   :trace_id, size: 36, null: false, unique: true
        String   :trace_type, null: false, default: 'episodic'
        String   :content, text: true, null: false, default: ''
        Float    :strength, default: 1.0
        Float    :peak_strength, default: 1.0
        Float    :base_decay_rate, default: 0.02
        Float    :emotional_valence
        Float    :emotional_intensity, default: 0.0
        String   :domain_tags, text: true
        String   :origin
        String   :storage_tier, default: 'hot'
        DateTime :created_at
        DateTime :last_reinforced
        DateTime :last_decayed
        Integer  :reinforcement_count, default: 0
        Float    :confidence, default: 0.5
        String   :partition_id
        String   :associated_traces, text: true
        String   :parent_id
        String   :child_ids, text: true
        TrueClass :unresolved, default: false
        TrueClass :consolidation_candidate, default: false
      end
      d.create_table(:memory_associations) do
        primary_key :id
        String :trace_id_a, size: 36, null: false
        String :trace_id_b, size: 36, null: false
        Integer :coactivation_count, default: 1, null: false
        String :partition_id
        unique %i[trace_id_a trace_id_b]
      end
      d
    end

    let(:data_local_stub) do
      conn = local_db
      Module.new do
        define_singleton_method(:connected?) { true }
        define_singleton_method(:connection) { conn }
        define_singleton_method(:table_exists?) { |name| conn.table_exists?(name) }
      end
    end

    before { stub_const('Legion::Data::Local', data_local_stub) }

    it 'does not log errors when nil optional columns are deserialized on load' do
      local_db[:memory_traces].insert(
        trace_id:          SecureRandom.uuid,
        trace_type:        'episodic',
        content:           'plain text content',
        partition_id:      'default',
        strength:          1.0,
        domain_tags:       nil,
        associated_traces: nil,
        child_ids:         nil,
        emotional_valence: nil
      )

      fresh = described_class.new
      expect(fresh.count).to eq(1)
      trace = fresh.traces.values.first
      expect(trace[:domain_tags]).to eq([])
      expect(trace[:associated_traces]).to eq([])
      expect(trace[:child_trace_ids]).to eq([])
    end

    it 'does not resurrect deleted association references after a restart' do
      store.store(semantic_trace)
      store.store(episodic_trace)
      trace_helper::COACTIVATION_THRESHOLD.times do
        store.record_coactivation(semantic_trace[:trace_id], episodic_trace[:trace_id])
      end
      store.flush

      store.delete(episodic_trace[:trace_id])
      store.flush
      restarted = described_class.new

      expect(restarted.get(episodic_trace[:trace_id])).to be_nil
      expect(restarted.get(semantic_trace[:trace_id])[:associated_traces]).to eq([])
      expect(restarted.retrieve_associated(semantic_trace[:trace_id])).to eq([])
    end
  end

  describe '#restore_traces' do
    it 'replaces existing traces and clears stale associations' do
      store.store(semantic_trace)
      store.store(episodic_trace)

      threshold = Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace::COACTIVATION_THRESHOLD
      threshold.times { store.record_coactivation(semantic_trace[:trace_id], episodic_trace[:trace_id]) }

      replacement = trace_helper.new_trace(type: :semantic, content_payload: { fact: 'replacement' })
      store.restore_traces([replacement])

      expect(store.count).to eq(1)
      expect(store.get(semantic_trace[:trace_id])).to be_nil
      expect(store.associations).to be_empty
    end
  end
end
