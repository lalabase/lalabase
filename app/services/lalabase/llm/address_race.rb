# frozen_string_literal: true

require 'socket'

# Opens a TCP connection to the first of several addresses that answers, the way Ruby
# connects to a name with several addresses (Happy Eyeballs, RFC 8305): the next
# address starts 250 ms after the previous one, or at once when it fails, and the
# earlier attempts keep running. The first connection wins and the others are closed.
#
# Lalabase::Llm::PublicEndpointAdapter needs it because it connects to CHECKED
# addresses, not to the name, and so cannot leave the choice to Ruby. Without the race
# an endpoint whose IPv6 address drops packets would spend the whole open timeout on
# that address and never try IPv4.
#
# It knows nothing about which addresses are allowed; the caller passes only checked
# ones.
module Lalabase
  module Llm
    class AddressRace
      # RFC 8305 §5, and what Ruby uses for names.
      CONNECTION_ATTEMPT_DELAY = 0.25

      def self.call(**kwargs)
        new(**kwargs).call
      end

      # @param addresses [Array<String>] IP literals, tried in the given order
      # @param port [Integer]
      # @param deadline [Float, nil] monotonic clock value; nil waits without a limit
      def initialize(addresses:, port:, deadline:)
        @waiting = addresses.map { |address| Addrinfo.tcp(address, port) }
        @deadline = deadline
        @pending = []
        @last_error = nil
        @next_start = monotonic_now
      end

      # @return [TCPSocket] connected
      # @raise [Net::OpenTimeout] when the deadline passes first
      # @raise [SystemCallError] the last failure, when every address failed
      def call
        loop do
          raise Net::OpenTimeout, 'execution expired' if @deadline && monotonic_now >= @deadline

          start_next_attempt if @waiting.any? && monotonic_now >= @next_start
          raise @last_error if @pending.empty? && @waiting.empty?

          winner = wait_for_an_attempt
          return as_tcp_socket(winner) if winner
        end
      ensure
        @pending.each(&:close)
      end

      private

      def start_next_attempt
        @pending << open_attempt(@waiting.shift)
        @next_start = monotonic_now + CONNECTION_ATTEMPT_DELAY
      rescue SystemCallError => e
        # Failed at once (refused, no route, no IPv6 on this host): the next address
        # starts in the next round, without waiting for the delay.
        @last_error = e
      end

      # A socket whose connect is under way. One that connected at once is writable
      # straight away, and the wait picks it up like any other.
      def open_attempt(addrinfo)
        socket = Socket.new(addrinfo.afamily, Socket::SOCK_STREAM, 0)
        socket.connect_nonblock(addrinfo, exception: false)
        socket
      rescue SystemCallError
        socket&.close
        raise
      end

      # Waits until an attempt finishes, the next one is due, or the deadline passes.
      # Returns the connected socket, or nil to go round again.
      def wait_for_an_attempt
        _, writable, = IO.select(nil, @pending, nil, wait_seconds)
        Array(writable).each do |socket|
          @pending.delete(socket)
          error = connect_error(socket)
          return socket if error.nil?

          socket.close
          @last_error = error
          @next_start = monotonic_now
        end
        nil
      end

      def wait_seconds
        until_next = @next_start if @waiting.any?
        limit = [until_next, @deadline].compact.min
        limit && [limit - monotonic_now, 0].max
      end

      def connect_error(socket)
        code = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        code.zero? ? nil : SystemCallError.new('connect(2)', code)
      end

      # Net::HTTP expects the socket TCPSocket.open returns (#peeraddr, among others).
      # The descriptor moves to the TCPSocket; the Socket must not close it when it is
      # collected.
      def as_tcp_socket(socket)
        socket.autoclose = false
        TCPSocket.for_fd(socket.fileno)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
