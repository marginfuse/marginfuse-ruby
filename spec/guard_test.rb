# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"
require "marginfuse"

# What guard reports after the call ran: which model, which vendor, and what the
# acknowledgment says. These live here rather than in the shared vectors because
# they are about what this SDK sends, not about what an adapter produces.
class GuardTest < Minitest::Test
  # A stub of the MarginFuse API, over a real socket, so the assertions are on
  # what actually went on the wire. The SDK opens a connection per request and
  # track and acknowledge run on background threads, so requests arrive
  # concurrently and the log is guarded.
  class StubServer
    def initialize(decision)
      @decision = decision
      @requests = []
      @mutex = Mutex.new
      @socket = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
      @thread.report_on_exception = false
    end

    def base_url
      "http://127.0.0.1:#{@socket.addr[1]}"
    end

    # The parsed bodies of every request that reached +path+, in arrival order.
    def bodies_for(path)
      @mutex.synchronize { @requests.select { |r| r[:path] == path }.map { |r| r[:body] } }
    end

    def close
      @socket.close
      @thread.kill
    end

    private

    def serve
      loop do
        connection = @socket.accept
        Thread.new { handle(connection) }.report_on_exception = false
      end
    rescue IOError, Errno::EBADF
      # the test closed the listener
    end

    def handle(connection)
      path = connection.gets.to_s.split[1]
      length = 0
      while (line = connection.gets) && line != "\r\n"
        length = line.split(":", 2)[1].to_i if line.match?(/\Acontent-length:/i)
      end
      body = length.positive? ? connection.read(length) : "{}"
      @mutex.synchronize { @requests << { path: path, body: JSON.parse(body) } }

      respond(connection, path == "/v1/decisions" ? @decision : {})
    ensure
      connection.close
    end

    def respond(connection, payload)
      json = JSON.generate(payload)
      connection.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    end
  end

  # The server downgrades an OpenAI request onto an Anthropic model. Crossing
  # vendors is the case where the caller's provider and the one that ran differ.
  CROSS_PROVIDER_DOWNGRADE = {
    "id" => "dec_downgrade",
    "action" => "downgrade",
    "model" => "claude-haiku-4.5",
    "provider" => "anthropic"
  }.freeze

  def with_server(decision)
    server = StubServer.new(decision)
    client = MarginFuse::Client.new(api_key: "mf_test", base_url: server.base_url)
    yield server, client
  ensure
    client&.flush
    server&.close
  end

  def only_event(server)
    events = server.bodies_for("/v1/events")

    assert_equal 1, events.length
    events.first.fetch("events").first
  end

  def test_a_cross_provider_downgrade_is_billed_to_the_vendor_that_ran
    with_server(CROSS_PROVIDER_DOWNGRADE) do |server, mf|
      handed = nil
      outcome = mf.guard(customer_id: "cus_8x2m91", provider: "openai", model: "gpt-4.1") do |d|
        handed = [d.provider, d.model]
        { result: "ok", usage: { input_tokens: 1204, output_tokens: 388 } }
      end
      mf.flush

      assert_predicate outcome, :completed?
      assert_equal %w[anthropic claude-haiku-4.5], handed

      event = only_event(server)

      assert_equal "anthropic", event["provider"]
      assert_equal "claude-haiku-4.5", event["model"]
      assert_equal "gpt-4.1", event["requestedModel"]
      assert_equal "used_downgrade_model",
                   server.bodies_for("/v1/decisions/dec_downgrade/ack").first["acknowledgment"]
    end
  end

  def test_a_downgrade_whose_provider_call_fails_is_still_a_downgrade
    with_server(CROSS_PROVIDER_DOWNGRADE) do |server, mf|
      failure = RuntimeError.new("provider exploded")
      raised = assert_raises(RuntimeError) do
        mf.guard(customer_id: "cus_8x2m91", provider: "openai", model: "gpt-4.1") { raise failure }
      end
      mf.flush

      # The application's own error, not one of ours, and not a wrapped copy.
      assert_same failure, raised

      event = only_event(server)

      assert_equal "provider_error", event["outcome"]
      assert_equal "anthropic", event["provider"]
      assert_equal "claude-haiku-4.5", event["model"]
      assert_equal "gpt-4.1", event["requestedModel"]
      assert_equal "used_downgrade_model",
                   server.bodies_for("/v1/decisions/dec_downgrade/ack").first["acknowledgment"]
    end
  end

  def test_anything_but_a_downgrade_reports_the_vendor_the_caller_asked_for
    # The server sends no provider, which is the ordinary case: the decision
    # defaults it to the caller's, so nothing about this report changes.
    allow = { "id" => "dec_allow", "action" => "allow" }
    with_server(allow) do |server, mf|
      mf.guard(customer_id: "cus_8x2m91", provider: "openai", model: "gpt-4.1") do
        { result: "ok", usage: { input_tokens: 1204, output_tokens: 388 } }
      end
      mf.flush

      event = only_event(server)

      assert_equal "openai", event["provider"]
      assert_equal "gpt-4.1", event["model"]
      assert_equal "proceeded_as_requested",
                   server.bodies_for("/v1/decisions/dec_allow/ack").first["acknowledgment"]
    end
  end
end
