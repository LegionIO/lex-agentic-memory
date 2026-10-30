# frozen_string_literal: true

RSpec.describe Legion::Extensions::Agentic::Memory::Trace::Helpers::CacheStore do
  let(:cache) { {} }
  let(:trace_helper) { Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace }

  before do
    allow(Legion::Cache).to receive(:get) do |key, **|
      Marshal.load(cache[key]) if cache.key?(key) # rubocop:disable Security/MarshalLoad -- Bytes are produced only by this isolated fixture.
    end
    allow(Legion::Cache).to receive(:set) do |key, value, **|
      cache[key] = Marshal.dump(value)
      true
    end
    allow(Legion::Cache).to receive(:delete) { |key, **| cache.delete(key) }
  end

  it 'keeps trace contents, indexes, and deletion isolated across agent restarts' do
    alice = described_class.new(partition_id: 'alice')
    bob = described_class.new(partition_id: 'bob')
    trace = trace_helper.new_trace(type: :semantic, content_payload: { fact: 'alice' }, partition_id: 'alice')
    alice.store(trace)
    bob.store(trace.merge(content_payload: { fact: 'bob' }, partition_id: 'bob'))
    alice.flush
    bob.flush

    alice = described_class.new(partition_id: 'alice')
    bob = described_class.new(partition_id: 'bob')
    expect(alice.get(trace[:trace_id])[:content_payload]).to eq(fact: 'alice')
    expect(bob.get(trace[:trace_id])[:content_payload]).to eq(fact: 'bob')

    alice.delete(trace[:trace_id])
    alice.flush
    bob.reload
    expect(described_class.new(partition_id: 'alice').all_traces).to eq([])
    expect(bob.get(trace[:trace_id])[:content_payload]).to eq(fact: 'bob')
  end

  it 'does not hydrate ambiguous legacy global cache records' do
    private_trace = trace_helper.new_trace(type: :semantic, content_payload: { fact: 'private' }, partition_id: 'bob')
    legacy_writer = described_class.new(partition_id: 'legacy-fixture')
    legacy_writer.cache_set('legion:memory:trace_index', [private_trace[:trace_id]])
    legacy_writer.cache_set("legion:memory:trace:#{private_trace[:trace_id]}", private_trace)
    legacy_records = cache.dup

    expect(described_class.new(partition_id: 'alice').all_traces).to eq([])
    expect(described_class.new(partition_id: 'bob').all_traces).to eq([])

    store = described_class.new(partition_id: 'alice')
    store.store(private_trace.merge(content_payload: { fact: 'new scoped trace' }, partition_id: 'alice'))
    store.flush
    store.delete(private_trace[:trace_id])
    store.flush

    expect(cache.slice(*legacy_records.keys)).to eq(legacy_records)
  end

  it 'preserves scoped coactivation progress and persisted links without resurrecting deleted links' do
    store = described_class.new(partition_id: 'alice')
    first = trace_helper.new_trace(type: :semantic, content_payload: { fact: 'first' }, partition_id: 'alice')
    second = trace_helper.new_trace(type: :semantic, content_payload: { fact: 'second' }, partition_id: 'alice')
    store.store(first)
    store.store(second)
    store.record_coactivation(first[:trace_id], second[:trace_id])
    store.flush

    restarted = described_class.new(partition_id: 'alice')
    (trace_helper::COACTIVATION_THRESHOLD - 1).times do
      restarted.record_coactivation(first[:trace_id], second[:trace_id])
    end
    restarted.flush
    restarted.reload

    expect(restarted.retrieve_associated(first[:trace_id]).map { |trace| trace[:trace_id] }).to eq([second[:trace_id]])
    expect(described_class.new(partition_id: 'bob').associations).to eq({})

    restarted.delete(second[:trace_id])
    restarted.flush
    restarted.reload
    expect(restarted.get(second[:trace_id])).to be_nil
    expect(restarted.get(first[:trace_id])[:associated_traces]).to eq([])
    expect(restarted.associations.fetch(first[:trace_id], {})).to eq({})
  end
end
