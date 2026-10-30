# frozen_string_literal: true

require 'legion/extensions/agentic/memory/trace/client'

RSpec.describe Legion::Extensions::Agentic::Memory::Trace::Runners::Traces do
  before(:each) { Legion::Extensions::Agentic::Memory::Trace.reset_store! }

  let(:client) { Legion::Extensions::Agentic::Memory::Trace::Client.new }

  describe '#store_trace' do
    it 'stores a semantic trace and returns id' do
      result = client.store_trace(type: :semantic, content_payload: { fact: 'test' })
      expect(result[:trace_id]).to match(/\A[0-9a-f-]{36}\z/)
      expect(result[:trace_type]).to eq(:semantic)
      expect(result[:strength]).to eq(0.5)
    end

    it 'stores all 7 trace types' do
      Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace::TRACE_TYPES.each do |type|
        result = client.store_trace(type: type, content_payload: {})
        expect(result[:trace_type]).to eq(type)
      end
    end
  end

  describe '#get_trace' do
    it 'retrieves a stored trace' do
      stored = client.store_trace(type: :episodic, content_payload: { event: 'meeting' })
      result = client.get_trace(trace_id: stored[:trace_id])
      expect(result[:found]).to be true
      expect(result[:trace][:content_payload]).to eq({ event: 'meeting' })
    end

    it 'returns found: false for missing traces' do
      result = client.get_trace(trace_id: 'nonexistent')
      expect(result[:found]).to be false
    end
  end

  describe '#retrieve_by_type' do
    it 'returns traces of specified type' do
      client.store_trace(type: :semantic, content_payload: { fact: 'a' })
      client.store_trace(type: :semantic, content_payload: { fact: 'b' })
      client.store_trace(type: :episodic, content_payload: { event: 'c' })

      result = client.retrieve_by_type(type: :semantic)
      expect(result[:count]).to eq(2)
    end
  end

  describe '#retrieve_by_domain' do
    it 'returns traces matching domain tag' do
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['work'])
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['personal'])

      result = client.retrieve_by_domain(domain_tag: 'work')
      expect(result[:count]).to eq(1)
    end
  end

  describe 'scoped retrieval' do
    let(:alice) do
      client.store_trace(type: :semantic, content_payload: { fact: 'alice work' }, domain_tags: ['work', 'partner:alice'])
    end
    let(:bob) do
      client.store_trace(type: :identity, content_payload: { fact: 'bob work' }, domain_tags: ['work', 'owner:bob'])
    end
    let(:unrelated) do
      client.store_trace(type: :identity, content_payload: { fact: 'alice home' }, domain_tags: ['home', 'partner:alice'])
    end
    let(:ids) { [alice, bob, unrelated].map { |trace| trace[:trace_id] } }

    it 'filters ranked candidates by principal and domain without reinforcing them' do
      before = client.get_trace(trace_id: alice[:trace_id])[:trace].dup

      result = client.retrieve_ranked(trace_ids: ids, domain_tag: 'work', identity: 'alice')

      expect(result[:traces].map { |entry| entry[:trace][:trace_id] }).to eq([alice[:trace_id]])
      expect(result[:traces].first[:score]).to be > 0
      expect(client.get_trace(trace_id: alice[:trace_id])[:trace]).to eq(before)
    end

    it 'does not return private or conflicting-owner traces to an anonymous or different principal' do
      shared = client.store_trace(type: :semantic, content_payload: { fact: 'public' }, domain_tags: ['work'])
      mixed = client.store_trace(type: :semantic, content_payload: {},
                                 domain_tags: ['work', 'partner:alice', 'owner:bob'])
      candidates = ids + [shared[:trace_id], mixed[:trace_id]]

      anonymous = client.retrieve_ranked(trace_ids: candidates, identity: nil)
      scoped = client.retrieve_ranked(trace_ids: candidates, domain_tag: 'work', identity: 'alice')

      expect(anonymous[:traces].map { |entry| entry[:trace][:trace_id] }).to eq([shared[:trace_id]])
      expect(scoped[:traces].map { |entry| entry[:trace][:trace_id] }).to contain_exactly(alice[:trace_id], shared[:trace_id])
    end

    it 'keeps unscoped explicit candidate ranking available to standalone callers' do
      result = client.retrieve_ranked(trace_ids: ids)

      expect(result[:traces].map { |entry| entry[:trace][:trace_id] }).to contain_exactly(*ids)
      expect(client.retrieve_ranked[:traces]).to eq([])
    end

    it 'reinforces only authorized relevant candidates before applying the limit' do
      result = client.retrieve_and_reinforce(trace_ids: ids + [alice[:trace_id]], domain_tag: 'work', identity: 'alice', limit: 1)

      expect(result[:traces].map { |trace| trace[:trace_id] }).to eq([alice[:trace_id]])
      expect(client.get_trace(trace_id: alice[:trace_id])[:trace][:reinforcement_count]).to eq(1)
      expect(client.get_trace(trace_id: bob[:trace_id])[:trace][:reinforcement_count]).to eq(0)
      expect(client.get_trace(trace_id: unrelated[:trace_id])[:trace][:reinforcement_count]).to eq(0)
    end

    it 'does not fall back to global traces when an explicit candidate list is empty' do
      alice

      expect(client.retrieve_and_reinforce(trace_ids: [])).to eq(count: 0, traces: [])
      expect(client.get_trace(trace_id: alice[:trace_id])[:trace][:reinforcement_count]).to eq(0)
    end

    it 'selects domain candidates from the store when no ids are supplied' do
      ids

      result = client.retrieve_and_reinforce(domain_tag: 'work', identity: 'alice', limit: 1)

      expect(result[:traces].map { |trace| trace[:trace_id] }).to eq([alice[:trace_id]])
      expect(client.get_trace(trace_id: bob[:trace_id])[:trace][:reinforcement_count]).to eq(0)
    end
  end

  describe '#delete_trace' do
    it 'removes a trace' do
      stored = client.store_trace(type: :semantic, content_payload: {})
      client.delete_trace(trace_id: stored[:trace_id])
      result = client.get_trace(trace_id: stored[:trace_id])
      expect(result[:found]).to be false
    end
  end

  describe '#erase_partner!' do
    it 'erases all partner-tagged traces for the given identity' do
      3.times { client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['partner:alice']) }
      2.times { client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['partner:bob']) }

      result = client.erase_partner!(identity: 'alice')

      expect(result[:erased]).to be true
      expect(result[:identity]).to eq('alice')
      expect(result[:count]).to eq(3)

      expect(client.retrieve_by_domain(domain_tag: 'partner:alice')[:count]).to eq(0)
      expect(client.retrieve_by_domain(domain_tag: 'partner:bob')[:count]).to eq(2)
    end

    it 'erases owner-tagged traces for the given identity' do
      2.times { client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['owner:alice']) }
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['partner:alice'])

      result = client.erase_partner!(identity: 'alice')

      expect(result[:count]).to eq(3)
      expect(client.retrieve_by_domain(domain_tag: 'owner:alice')[:count]).to eq(0)
      expect(client.retrieve_by_domain(domain_tag: 'partner:alice')[:count]).to eq(0)
    end

    it 'returns count: 0 when no traces exist for the identity' do
      result = client.erase_partner!(identity: 'ghost')

      expect(result[:erased]).to be true
      expect(result[:identity]).to eq('ghost')
      expect(result[:count]).to eq(0)
    end

    it 'does not erase traces belonging to other identities' do
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['partner:alice'])
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['partner:bob'])
      client.store_trace(type: :semantic, content_payload: {}, domain_tags: ['owner:carol'])

      client.erase_partner!(identity: 'alice')

      expect(client.retrieve_by_domain(domain_tag: 'partner:bob')[:count]).to eq(1)
      expect(client.retrieve_by_domain(domain_tag: 'owner:carol')[:count]).to eq(1)
    end
  end
end
