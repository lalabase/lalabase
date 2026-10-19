# frozen_string_literal: true

# What: Lalabase::Llm::PublicEndpointAdapter, and the OpenAI-compatible provider that
#   uses it for an endpoint a customer typed.
# Why: a check at save time cannot hold. DNS answers again for every request, and a
#   name that pointed outward when it was saved can point at the app server when the
#   key is sent (DNS rebinding). So the address is judged again for every connection,
#   and the socket goes only to the addresses that were judged, never to a second
#   lookup of the name. The race across them has its own spec (address_race_spec.rb).

require 'rails_helper'
require 'socket'

RSpec.describe Lalabase::Llm::PublicEndpointAdapter, :ci_guard do
  def env_for(url)
    Faraday::Env.from(method: :get, url: URI(url), request: Faraday::RequestOptions.new,
                      ssl: Faraday::SSLOptions.new, request_headers: {})
  end

  def connection_for(url)
    described_class.new(->(env) { env }).send(:net_http_connection, env_for(url))
  end

  describe 'the connection it builds' do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:raced) { [] }

    after { server.close }

    # The race gets only checked addresses and hands back a socket to the local
    # listener, so these examples need no network.
    before do
      allow(Lalabase::Llm::AddressRace).to receive(:call) do |addresses:, port:, deadline:|
        raced << { addresses: addresses, port: port, deadline: deadline }
        TCPSocket.new('127.0.0.1', server.addr[1])
      end
    end

    def open(url)
      http = connection_for(url)
      http.start(&:started?)
      http
    end

    it 'connects only to the addresses it checked and keeps the name for TLS' do
      resolve_names('api.provider.example' => ['52.1.2.3', '2606:4700:4700::1111'])

      http = open("http://api.provider.example:#{server.addr[1]}/v1/models")

      expect(raced.last).to include(addresses: ['52.1.2.3', '2606:4700:4700::1111'], port: server.addr[1])
      expect(http.address).to eq('api.provider.example')
    end

    it 'refuses a name that points inward, before any connect' do
      resolve_names('localhost.attacker.example' => ['127.0.0.1'])

      expect { open('https://localhost.attacker.example/v1/models') }
        .to raise_error(described_class::EndpointNotPublicError)
      expect(raced).to be_empty
    end

    # Rebinding: the first answer was public (that is what the save saw), the next
    # one is not. The adapter asks again and refuses.
    it 'judges the address again for every connection' do
      answers = [['52.1.2.3'], ['127.0.0.1']]
      Lalabase::PublicAddress.resolver = ->(_hostname, **) { answers.shift }

      open("http://rebind.attacker.example:#{server.addr[1]}/v1")
      expect { open("http://rebind.attacker.example:#{server.addr[1]}/v1") }
        .to raise_error(described_class::EndpointNotPublicError)
      expect(raced.size).to eq(1)
    end

    # Given the name, Net::HTTP spent its open timeout on the lookup AND the connect.
    # A lookup outside it would let a slow resolver hold a worker past the budget.
    it 'counts the DNS lookup against the open timeout' do
      lookup = {}
      Lalabase::PublicAddress.resolver = lambda do |_hostname, timeout:|
        lookup[:timeout] = timeout
        sleep 0.2
        ['52.1.2.3']
      end
      http = connection_for("http://slow-dns.provider.example:#{server.addr[1]}/v1")
      http.open_timeout = 0.3

      http.start(&:started?)

      expect(lookup[:timeout]).to eq(0.3)
      left_for_the_connect = raced.last[:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(left_for_the_connect).to be < 0.15
    end

    # Through a proxy the proxy resolves the name, and the addresses checked here would
    # mean nothing.
    it 'refuses to go through a proxy' do
      env = env_for('https://api.provider.example/v1')
      env.request.proxy = { uri: URI('http://proxy.example:3128') }

      expect { described_class.new(->(e) { e }).send(:net_http_connection, env) }
        .to raise_error(described_class::EndpointNotPublicError)
    end

    it 'is a connection failure to every rescue that already handles one' do
      expect(described_class::EndpointNotPublicError.ancestors).to include(Faraday::ConnectionFailed)
    end

    # Once connected, the request may have been written. A failure from there on must
    # not connect again: a chat request would run, and be billed, twice.
    it 'does not connect again when the request fails after the connect' do
      resolve_names('api.provider.example' => ['203.0.113.20', '203.0.113.21'])
      listener = Thread.new { loop { server.accept.close } }

      http = connection_for("http://api.provider.example:#{server.addr[1]}/v1")
      expect { http.request(Net::HTTP::Post.new('/v1/chat/completions')) }.to raise_error(StandardError)
      expect(raced.size).to eq(1)
    ensure
      listener&.kill
    end
  end

  # The seam is private to Net::HTTP; without it, Net::HTTP would resolve and connect
  # to the name on its own, unchecked.
  it 'sits on a Net::HTTP that still has the seam it takes over' do
    expect(Net::HTTP.private_method_defined?(:timeouted_connect)).to be(true)
  end

  # End to end, with the real OpenAI client: a listener on loopback stands for a
  # service on the app server, and a public-looking name resolves to it.
  describe 'Lalabase::Llm::OpenAiCompatibleProvider at request time' do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:accepted) { Queue.new }
    let(:port) { server.addr[1] }

    before do
      resolve_names('inward.attacker.example' => ['127.0.0.1'])
      @listener = Thread.new do
        loop do
          socket = server.accept
          accepted << true
          socket.close
        end
      end
    end

    after do
      @listener.kill
      server.close
    end

    def provider(endpoint, operator_endpoint:)
      Lalabase::Llm::OpenAiCompatibleProvider.new(api_key: 'sk-customer', uri_base: endpoint,
                                                  chat_model: 'm', operator_endpoint: operator_endpoint)
    end

    it 'never opens a socket to an endpoint a customer typed that points inward' do
      expect { provider("https://inward.attacker.example:#{port}/v1", operator_endpoint: false).connectivity_check }
        .to raise_error(described_class::EndpointNotPublicError)

      sleep 0.2
      expect(accepted).to be_empty
    end

    # The other side: an endpoint the operator configured (a model server next to the
    # app on a self-hosted instance) is not the customer's to choose and stays reachable.
    # A literal, because this path does not ask Lalabase::PublicAddress and so does not
    # see the names the spec resolver knows.
    it 'still connects to an endpoint the operator configured' do
      expect { provider("https://127.0.0.1:#{port}/v1", operator_endpoint: true).connectivity_check }
        .to raise_error(StandardError)

      expect(accepted.pop(timeout: 5)).to be(true)
    end
  end
end
