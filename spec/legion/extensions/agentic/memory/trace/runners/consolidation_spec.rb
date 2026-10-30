# frozen_string_literal: true

require 'legion/extensions/agentic/memory/trace/client'

RSpec.describe Legion::Extensions::Agentic::Memory::Trace::Runners::Consolidation do
  before(:each) { Legion::Extensions::Agentic::Memory::Trace.reset_store! }

  let(:client) { Legion::Extensions::Agentic::Memory::Trace::Client.new }

  describe '#reinforce' do
    it 'increases trace strength' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      result = client.reinforce(trace_id: stored[:trace_id])

      expect(result[:reinforced]).to be true
      expect(result[:new_strength]).to eq(0.6) # 0.5 + 0.1
    end

    it 'applies imprint multiplier' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      result = client.reinforce(trace_id: stored[:trace_id], imprint_active: true)

      expect(result[:new_strength]).to eq(0.8) # 0.5 + 0.1 * 3.0
    end

    it 'does not reinforce firmware traces' do
      stored = client.store_trace(type: :firmware, content_payload: { directive_text: 'protect' })
      result = client.reinforce(trace_id: stored[:trace_id])

      expect(result[:reinforced]).to be false
      expect(result[:reason]).to eq(:firmware)
    end

    it 'returns found: false for missing traces' do
      result = client.reinforce(trace_id: 'nonexistent')
      expect(result[:found]).to be false
    end

    it 'clamps at 1.0' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      # Reinforce multiple times
      10.times { client.reinforce(trace_id: stored[:trace_id]) }
      trace = client.get_trace(trace_id: stored[:trace_id])
      expect(trace[:trace][:strength]).to eq(1.0)
    end

    it 'increments reinforcement_count' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      3.times { client.reinforce(trace_id: stored[:trace_id]) }
      trace = client.get_trace(trace_id: stored[:trace_id])
      expect(trace[:trace][:reinforcement_count]).to eq(3)
    end
  end

  describe '#decay_cycle' do
    it 'does not initialize the shared store when Gaia defers heartbeat maintenance' do
      runner = Object.new.extend(described_class)
      allow(Legion::Extensions::Agentic::Memory::Trace).to receive(:shared_store)

      result = runner.decay_cycle(maintenance: false)

      expect(Legion::Extensions::Agentic::Memory::Trace).not_to have_received(:shared_store)
      expect(result).to include(
        decayed:   0,
        pruned:    0,
        total:     0,
        remaining: 0,
        deferred:  true,
        reason:    :background_decay_actor
      )
    end

    it 'defers Gaia heartbeat decay work to the background actor when maintenance is false' do
      client.store_trace(type: :semantic, content_payload: {})

      result = client.decay_cycle(maintenance: false)
      expect(result).to include(
        decayed:   0,
        pruned:    0,
        total:     1,
        remaining: 1,
        deferred:  true,
        reason:    :background_decay_actor
      )
    end

    it 'reuses the latest maintenance summary when decay is deferred' do
      client.store_trace(type: :semantic, content_payload: {})
      client.decay_cycle(tick_count: 100)

      result = client.decay_cycle(maintenance: false)
      expect(result[:deferred]).to be true
      expect(result[:total]).to be >= result[:remaining]
      expect(result[:maintained_at]).not_to be_nil
    end

    it 'decays non-firmware traces' do
      client.store_trace(type: :semantic, content_payload: {})
      client.store_trace(type: :firmware, content_payload: { directive_text: 'protect' })

      result = client.decay_cycle(tick_count: 100)
      expect(result[:decayed]).to be >= 1
    end

    it 'continues the same power-law aging across repeated maintenance and snapshot restore' do
      started_at = Time.utc(2026, 10, 29)
      allow(Time).to receive(:now).and_return(started_at)
      store = Legion::Extensions::Agentic::Memory::Trace::Helpers::Store.new
      stored = client.store_trace(type: :semantic, content_payload: {}, store: store)
      id = stored[:trace_id]

      allow(Time).to receive(:now).and_return(started_at + 60)
      client.decay_cycle(store: store)
      first_strength = store.get(id)[:strength]
      expect(first_strength).to be_within(1e-12).of(0.5 * (2.0**-0.01))

      restored = Legion::Extensions::Agentic::Memory::Trace::Helpers::Store.new
      restored.restore_traces(Marshal.load(Marshal.dump(store.all_traces)))
      allow(Time).to receive(:now).and_return(started_at + 120)
      client.decay_cycle(store: restored)

      expect(restored.get(id)[:strength]).to be_within(1e-12).of(0.5 * (3.0**-0.01))
      expect(restored.get(id)[:strength]).to be < first_strength
      second_strength = restored.get(id)[:strength]
      client.decay_cycle(store: restored)
      expect(restored.get(id)[:strength]).to eq(second_strength)
    end

    it 'restarts aging from explicit reinforcement without restoring historical peak strength during maintenance' do
      started_at = Time.utc(2026, 10, 29)
      allow(Time).to receive(:now).and_return(started_at)
      id = client.store_trace(type: :semantic, content_payload: {})[:trace_id]

      client.decay_cycle(tick_count: 100)
      aged_strength = client.get_trace(trace_id: id)[:trace][:strength]
      client.decay_cycle
      expect(client.get_trace(trace_id: id)[:trace][:strength]).to eq(aged_strength)

      allow(Time).to receive(:now).and_return(started_at + 120)
      reinforced = client.reinforce(trace_id: id)[:new_strength]
      allow(Time).to receive(:now).and_return(started_at + 180)
      client.decay_cycle

      expect(client.get_trace(trace_id: id)[:trace][:strength]).to be_within(1e-12).of(reinforced * (2.0**-0.01))
    end

    it 'prunes traces below threshold' do
      stored = client.store_trace(type: :sensory, content_payload: {})
      trace = client.get_trace(trace_id: stored[:trace_id])
      trace[:trace][:strength] = 0.005
      trace[:trace][:peak_strength] = 0.005

      result = client.decay_cycle(tick_count: 100_000)
      expect(result[:pruned]).to eq(1)
      expect(client.get_trace(trace_id: stored[:trace_id])[:found]).to be false
    end
  end

  describe '#migrate_tier' do
    it 'migrates traces to correct tier' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      trace = client.get_trace(trace_id: stored[:trace_id])
      trace[:trace][:last_reinforced] = Time.now.utc - (50 * 86_400)

      result = client.migrate_tier
      expect(result[:migrated]).to be >= 1
    end
  end

  describe '#hebbian_link' do
    it 'records coactivation' do
      a = client.store_trace(type: :semantic, content_payload: { fact: 'a' })
      b = client.store_trace(type: :semantic, content_payload: { fact: 'b' })

      result = client.hebbian_link(trace_id_a: a[:trace_id], trace_id_b: b[:trace_id])
      expect(result[:linked]).to be true
    end
  end

  describe '#erase_by_type' do
    it 'erases all traces of specified type' do
      client.store_trace(type: :sensory, content_payload: {})
      client.store_trace(type: :sensory, content_payload: {})
      client.store_trace(type: :semantic, content_payload: {})

      result = client.erase_by_type(type: :sensory)
      expect(result[:erased]).to eq(2)

      remaining = client.retrieve_by_type(type: :sensory)
      expect(remaining[:count]).to eq(0)
    end
  end

  describe '#erase_by_agent' do
    it 'erases all traces for a partition' do
      client.store_trace(type: :semantic, content_payload: {}, partition_id: 'agent-1')
      client.store_trace(type: :semantic, content_payload: {}, partition_id: 'agent-1')
      client.store_trace(type: :semantic, content_payload: {}, partition_id: 'agent-2')

      result = client.erase_by_agent(partition_id: 'agent-1')
      expect(result[:erased]).to eq(2)
    end
  end
end
