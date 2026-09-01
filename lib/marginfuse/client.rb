# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
# Time#iso8601 lives here. Some Rubies load it transitively and some do not, so
# a library that assumes it is present throws into the caller on the ones that
# do not, which is the one thing this SDK promises never to do.
require "time"
require "uri"

module MarginFuse
  # Server-side SDK for MarginFuse: profitability guardrails for AI SaaS.
  #
  # Reliability contract: this SDK never raises into application code and never
  # blocks a request on MarginFuse availability. {#decide} fails open to
  # +:allow+ on any timeout or error; {#track} and {#acknowledge} retry on a
  # background thread and surface problems only through +on_error+.
  #
  # Zero dependencies, standard library only. Server side only: it carries a
  # secret API key.
  #
  #   mf = MarginFuse::Client.new(api_key: ENV.fetch("MARGINFUSE_KEY"))
  #   mf.track(customer_id: "cus_8x2m91", provider: "openai", model: "gpt-4.1",
  #            usage: { input_tokens: 1204, output_tokens: 388 })
  class Client
    DEFAULT_BASE_URL = "https://api.marginfuse.com"
    DEFAULT_TIMEOUT = 1.5
    TRACK_RETRIES = 3
    USER_AGENT = "marginfuse-ruby/#{VERSION}".freeze

    # Usage keys are snake_case here and camelCase on the wire.
    USAGE_KEYS = {
      input_tokens: "inputTokens",
      output_tokens: "outputTokens",
      cached_input_tokens: "cachedInputTokens",
      cache_creation_tokens: "cacheCreationTokens",
      images: "images",
      audio_seconds: "audioSeconds"
    }.freeze

    # @param api_key [String] your project API key
    # @param base_url [String] point at your own deployment in development
    # @param timeout [Float] seconds {#decide} waits before failing open
    # @param on_error [Proc] receives (error, context) for failures the SDK
    #   swallowed. Without it they are silent by design: this SDK is in your
    #   request path and must not become your outage.
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT, on_error: nil)
      raise ArgumentError, "MarginFuse: api_key is required" if api_key.nil? || api_key.empty?

      @api_key = api_key
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @on_error = on_error
      @pending = []
      @mutex = Mutex.new
    end

    # Asks whether the next call should run. Always returns a decision.
    #
    # On any timeout or error this returns +action: :allow+ with
    # +degraded: true+: MarginFuse being unreachable must never become your
    # outage.
    #
    # @return [Decision]
    def decide(customer_id:, provider:, model:, feature: nil, expected_usage: nil)
      body = {
        "customerId" => customer_id,
        "feature" => feature,
        "provider" => provider,
        "model" => model,
        "expectedUsage" => usage_payload(expected_usage)
      }.compact
      body.delete("expectedUsage") if body["expectedUsage"] && body["expectedUsage"].empty?

      response = post("/v1/decisions", body, @timeout)
      unless (200..299).cover?(response.code.to_i)
        report(RuntimeError.new("decide: HTTP #{response.code}"), "decide")
        return fail_open(provider, model, "server responded #{response.code}")
      end

      parsed = JSON.parse(response.body)
      Decision.new(
        id: parsed["id"],
        action: Decision.action_from_wire(parsed["action"]),
        model: parsed["model"] || model,
        provider: parsed["provider"] || provider,
        topup_context: parsed["topupContext"],
        degraded: parsed["degraded"] || false,
        degraded_reason: parsed["degradedReason"]
      )
    # Net::OpenTimeout, Net::ReadTimeout and Net::WriteTimeout are all
    # Timeout::Error, so this catches every way the request can time out,
    # including the one an explicit list would have missed.
    rescue Timeout::Error => e
      report(e, "decide")
      fail_open(provider, model, "timeout")
    rescue StandardError => e
      report(e, "decide")
      fail_open(provider, model, "unreachable")
    end

    # Reports a call that already happened. Returns immediately and sends on a
    # background thread with retries.
    #
    # Call {#flush} before the process exits, or the last events go with it.
    #
    # @return [void]
    def track(customer_id:, provider:, model:, usage: nil, feature: nil, requested_model: nil,
              cost_usd: nil, event_id: nil, occurred_at: nil, outcome: :success,
              decision_id: nil, retry_of_event_id: nil, corrects_event_id: nil)
      event = {
        "eventId" => event_id || "evt_#{SecureRandom.uuid}",
        "customerId" => customer_id,
        "feature" => feature,
        "provider" => provider,
        "model" => model,
        "requestedModel" => requested_model,
        "usage" => usage_payload(usage) || {},
        "costUsd" => cost_usd,
        "occurredAt" => (occurred_at || Time.now).utc.iso8601(6),
        "outcome" => outcome.to_s,
        "decisionId" => decision_id,
        "retryOfEventId" => retry_of_event_id,
        "correctsEventId" => corrects_event_id
      }.compact

      background { send_event(event) }
    end

    # {#track} for jobs and scripts that must not exit early.
    # @return [void]
    def track_and_wait(**params)
      track(**params)
      flush
    end

    # Tells MarginFuse what your application did with a decision.
    # @return [void]
    def acknowledge(decision_id, acknowledgment)
      background do
        response = post("/v1/decisions/#{URI.encode_www_form_component(decision_id)}/ack",
                        { "acknowledgment" => acknowledgment.to_s }, 5.0)
        unless (200..299).cover?(response.code.to_i)
          report(RuntimeError.new("ack: HTTP #{response.code}"), "acknowledge")
        end
      rescue StandardError => e
        report(e, "acknowledge")
      end
    end

    # Runs the whole loop: ask, run, report, acknowledge.
    #
    # Yields the decision to the block, which must return a hash with +:usage+
    # and optionally +:result+, +:cost_usd+ and +:outcome+. Use
    # +decision.model+: a downgrade verdict changes it.
    #
    # It yields rather than returning a decision for you to act on, because
    # enforcement must not depend on the caller remembering to check anything.
    # When the verdict is block, the block is never yielded to.
    #
    # An exception from your block propagates unchanged: your error handling
    # owns provider failures. The attempt is recorded first, because the
    # provider may still have charged for it.
    #
    # @return [GuardOutcome]
    def guard(customer_id:, provider:, model:, feature: nil, expected_usage: nil)
      decision = decide(customer_id: customer_id, provider: provider, model: model,
                        feature: feature, expected_usage: expected_usage)

      # Enforcement depends on the ACTION alone. A missing id costs an
      # acknowledgment; it must never turn a block into a provider call.
      if decision.action == :block
        acknowledge(decision.id, :blocked_before_provider_call) if decision.id
        return GuardOutcome.new(kind: :blocked, decision: decision)
      end
      if decision.action == :topup_required
        acknowledge(decision.id, :presented_topup) if decision.id
        return GuardOutcome.new(kind: :topup_required, decision: decision)
      end

      model_used = decision.action == :downgrade ? decision.model : model

      begin
        call = yield(decision)
      rescue Exception => e # rubocop:disable Lint/RescueException
        track(customer_id: customer_id, feature: feature, provider: provider,
              model: model_used, requested_model: model, usage: {},
              outcome: :provider_error, decision_id: decision.id)
        acknowledge(decision.id, :proceeded_as_requested) if decision.id
        raise e
      end

      call ||= {}
      track(customer_id: customer_id, feature: feature, provider: provider,
            model: model_used, requested_model: model, usage: call[:usage],
            cost_usd: call[:cost_usd], outcome: call[:outcome] || :success,
            decision_id: decision.id)
      if decision.id
        acknowledge(decision.id,
                    decision.action == :downgrade ? :used_downgrade_model : :proceeded_as_requested)
      end

      GuardOutcome.new(kind: :completed, decision: decision, result: call[:result])
    end

    # Waits for queued events and acknowledgments. Never raises.
    # @return [void]
    def flush
      threads = @mutex.synchronize { @pending.dup }
      threads.each do |thread|
        thread.join
      rescue StandardError
        # already surfaced through on_error
      end
      @mutex.synchronize { @pending.compact! }
      nil
    end

    private

    def fail_open(provider, model, reason)
      Decision.new(id: nil, action: :allow, model: model, provider: provider,
                   topup_context: nil, degraded: true, degraded_reason: reason)
    end

    def usage_payload(usage)
      return nil if usage.nil?

      USAGE_KEYS.each_with_object({}) do |(key, wire), out|
        value = usage.is_a?(Hash) ? (usage[key] || usage[key.to_s]) : nil
        out[wire] = value unless value.nil?
      end
    end

    def report(error, context)
      return if @on_error.nil?

      @on_error.call(error, context)
    rescue StandardError
      # a broken hook is not our failure mode
    end

    def background(&)
      thread = Thread.new(&)
      thread.report_on_exception = false
      @mutex.synchronize do
        @pending.select!(&:alive?)
        @pending << thread
      end
    end

    def send_event(event)
      last = nil
      attempt = 0
      while attempt < TRACK_RETRIES
        outcome, last = attempt_send(event)
        return if outcome == :done

        sleep(0.25 * (2**attempt))
        attempt += 1
      end
      report(last, "track") if last
    end

    # Returns [:done, nil] when there is nothing left to try, either because the
    # event landed or because retrying cannot help.
    def attempt_send(event)
      response = post("/v1/events", { "events" => [event] }, 5.0)
      status = response.code.to_i
      return [:done, nil] if (200..299).cover?(status)

      if (400..499).cover?(status) && status != 429
        # A malformed event is malformed on every attempt.
        report(RuntimeError.new("track: HTTP #{status} #{response.body.to_s[0, 200]}"), "track")
        return [:done, nil]
      end

      [:retry, RuntimeError.new("track: HTTP #{status}")]
    rescue StandardError => e
      [:retry, e]
    end

    def post(path, body, timeout)
      uri = URI.parse("#{@base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request["authorization"] = "Bearer #{@api_key}"
      request["content-type"] = "application/json"
      request["user-agent"] = USER_AGENT
      request.body = JSON.generate(body)

      http.request(request)
    end
  end
end
