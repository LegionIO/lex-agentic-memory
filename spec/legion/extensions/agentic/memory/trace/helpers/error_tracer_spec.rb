# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Agentic::Memory::Trace::Helpers::ErrorTracer do
  # Capture originals before any example runs so we can restore after each
  original_error = Legion::Logging.method(:error)
  original_fatal = Legion::Logging.method(:fatal)

  before do
    # Reset state between examples
    described_class.instance_variable_set(:@active, nil)
    described_class.instance_variable_set(:@recent, nil)
    described_class.instance_variable_set(:@recent_mutex, nil)
    described_class.instance_variable_set(:@runner, nil)
    described_class.instance_variable_set(:@write_queue, nil)
    old_worker = described_class.instance_variable_get(:@worker)
    old_worker&.kill
    described_class.instance_variable_set(:@worker, nil)
  end

  after do
    # Restore logging singleton methods to prevent cross-test side effects
    Legion::Logging.define_singleton_method(:error, &original_error)
    Legion::Logging.define_singleton_method(:fatal, &original_fatal)
    # Stop worker thread if still alive
    worker = described_class.instance_variable_get(:@worker)
    if worker&.alive?
      described_class.instance_variable_get(:@write_queue)&.push(:stop)
      worker.join(1)
    end
  end

  describe '.setup' do
    it 'activates without raising' do
      expect { described_class.setup }.not_to raise_error
      expect(described_class.active?).to be true
    end

    it 'is idempotent' do
      described_class.setup
      described_class.setup
      expect(described_class.active?).to be true
    end

    it 'starts a single background worker thread' do
      described_class.setup
      worker = described_class.instance_variable_get(:@worker)
      expect(worker).to be_a(Thread)
      expect(worker).to be_alive
    end
  end

  describe '.active?' do
    it 'returns false before setup' do
      expect(described_class.active?).to be false
    end

    it 'returns true after setup' do
      described_class.setup
      expect(described_class.active?).to be true
    end
  end

  describe 'record_trace (async dispatch via queue)' do
    let(:store_dbl) { double('store', flush: nil) }
    let(:runner_double) do
      dbl = double('runner')
      allow(dbl).to receive(:store_trace)
      allow(dbl).to receive(:default_store).and_return(store_dbl)
      dbl
    end
    let(:write_queue) { Queue.new }

    before do
      described_class.instance_variable_set(:@active, true)
      described_class.instance_variable_set(:@recent, {})
      described_class.instance_variable_set(:@recent_mutex, Mutex.new)
      described_class.instance_variable_set(:@runner, runner_double)
      described_class.instance_variable_set(:@write_queue, write_queue)
    end

    it 'enqueues a payload hash (fire-and-forget dispatch)' do
      described_class.send(:record_trace, 'something broke', :error)
      expect(write_queue.size).to eq(1)
      payload = write_queue.pop
      expect(payload).to be_a(Hash)
    end

    it 'enqueues a payload with expected keys' do
      described_class.send(:record_trace, '[mycomponent] disk full', :error)
      payload = write_queue.pop
      expect(payload).to include(
        type:            :episodic,
        content_payload: '[mycomponent] disk full',
        domain_tags:     %w[error mycomponent],
        unresolved:      true
      )
    end

    it 'uses fatal valence and intensity for :fatal level' do
      described_class.send(:record_trace, 'total meltdown', :fatal)
      payload = write_queue.pop
      expect(payload).to include(
        emotional_valence:   Legion::Extensions::Agentic::Memory::Trace::Helpers::ErrorTracer::FATAL_VALENCE,
        emotional_intensity: Legion::Extensions::Agentic::Memory::Trace::Helpers::ErrorTracer::FATAL_INTENSITY
      )
    end

    it 'does not enqueue (debounced) when same message is within the window' do
      described_class.send(:record_trace, 'repeated error', :error)
      described_class.send(:record_trace, 'repeated error', :error)
      expect(write_queue.size).to eq(1)
    end

    it 'returns nil for blank messages without raising' do
      expect(described_class.send(:record_trace, '', :error)).to be_nil
      expect(write_queue.size).to eq(0)
    end

    it 'does not propagate errors from store_trace' do
      worker_queue = Queue.new
      described_class.instance_variable_set(:@write_queue, worker_queue)
      allow(runner_double).to receive(:store_trace).and_raise(StandardError, 'db down')

      # rubocop:disable-next ThreadSafety/NewThread
      worker = Thread.new do
        payload = worker_queue.pop
        break if payload == :stop

        runner_double.store_trace(**payload)
      rescue StandardError
        nil
      end

      described_class.send(:record_trace, 'store failure', :error)
      expect { worker.join(2) }.not_to raise_error
    end

    it 'the background worker calls store_trace with the enqueued payload' do
      dedicated_queue = Queue.new
      described_class.instance_variable_set(:@write_queue, dedicated_queue)

      # rubocop:disable-next ThreadSafety/NewThread
      worker = Thread.new do
        loop do
          payload = dedicated_queue.pop
          break if payload == :stop

          runner_double.store_trace(**payload)
          store = runner_double.send(:default_store)
          store.flush if store.respond_to?(:flush)
        rescue StandardError
          nil
        end
      end

      described_class.send(:record_trace, '[mycomponent] disk full', :error)
      dedicated_queue.push(:stop)
      worker.join(2)

      expect(runner_double).to have_received(:store_trace).with(
        hash_including(
          type:            :episodic,
          content_payload: '[mycomponent] disk full',
          domain_tags:     %w[error mycomponent],
          unresolved:      true
        )
      )
    end
  end
end
