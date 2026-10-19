# frozen_string_literal: true

# What: Lalabase::Llm::AddressRace, the TCP connect over the checked addresses of a
#   customer endpoint.
# Why: given the name, Ruby races the addresses (Happy Eyeballs) inside one open
#   timeout. Connecting to checked addresses one after the other lost both: an address
#   that drops packets used up the timeout before the next one was tried, and every
#   address got a timeout of its own. Each example pins one half of what Ruby did.
#
# A stalled attempt is the write end of a full pipe in place of the socket: it never
# becomes writable while nobody reads, which is what a connect to an address that
# drops packets looks like, and it does not depend on how the network of the machine
# running the spec treats a documentation address.

require 'rails_helper'
require 'socket'

RSpec.describe Lalabase::Llm::AddressRace, :ci_guard do
  let(:server) { TCPServer.new('127.0.0.1', 0) }
  let(:port) { server.addr[1] }
  let(:stalled) { [] }
  let(:readers) { [] }

  after do
    server.close
    readers.each(&:close)
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Addresses from 192.0.2.0/24 stall; every other one is really connected.
  def race(addresses, timeout:)
    instance = described_class.new(addresses: addresses, port: port, deadline: now + timeout)
    allow(instance).to receive(:open_attempt).and_wrap_original do |original, addrinfo|
      next original.call(addrinfo) unless addrinfo.ip_address.start_with?('192.0.2.')

      reader, writer = IO.pipe
      readers << reader
      nil while writer.write_nonblock('x' * 65_536, exception: false) != :wait_writable
      stalled << writer
      writer
    end
    instance.call
  end

  it 'returns a connected TCPSocket, which Net::HTTP expects' do
    socket = race(['127.0.0.1'], timeout: 2)

    expect(socket).to be_a(TCPSocket)
    expect(socket.peeraddr[3]).to eq('127.0.0.1')
  ensure
    socket&.close
  end

  it 'tries the next address after the attempt delay while the first one stalls' do
    started = now
    socket = race(['192.0.2.1', '127.0.0.1'], timeout: 2)

    expect(socket.peeraddr[1]).to eq(port)
    expect(now - started).to be_between(described_class::CONNECTION_ATTEMPT_DELAY - 0.05, 1.0)
    expect(stalled).to all(be_closed)
  ensure
    socket&.close
  end

  it 'starts the next address at once when one fails' do
    started = now
    # Nothing listens on ::1 at this port: refused, or unavailable without IPv6.
    socket = race(['::1', '127.0.0.1'], timeout: 2)

    expect(socket.peeraddr[3]).to eq('127.0.0.1')
    expect(now - started).to be < described_class::CONNECTION_ATTEMPT_DELAY
  ensure
    socket&.close
  end

  it 'spends one timeout on all addresses together' do
    started = now

    expect { race(['192.0.2.1', '192.0.2.2', '192.0.2.3'], timeout: 0.3) }.to raise_error(Net::OpenTimeout)
    expect(now - started).to be < 0.6
    expect(stalled).to all(be_closed)
  end

  it 'raises the last failure when every address fails' do
    free_port = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }
    instance = described_class.new(addresses: ['::1', '127.0.0.1'], port: free_port, deadline: now + 2)

    expect { instance.call }.to raise_error(SystemCallError)
  end
end
