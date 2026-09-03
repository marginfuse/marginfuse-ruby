# frozen_string_literal: true

module MarginFuse
  # The wire values for a verdict. An action a newer server sends and this
  # version cannot enforce resolves to :allow, because an unrecognised value
  # must never silently become a block.
  DECISION_ACTIONS = {
    "allow" => :allow,
    "downgrade" => :downgrade,
    "topup_required" => :topup_required,
    "block" => :block
  }.freeze

  # A verdict from MarginFuse.
  #
  # +degraded+ is true when MarginFuse could not reach a verdict and the request
  # was allowed through unprotected. +id+ is nil in that case, which is exactly
  # why enforcement must depend on +action+ alone.
  Decision = Struct.new(
    :id, :action, :model, :provider, :topup_context, :degraded, :degraded_reason,
    keyword_init: true
  ) do
    def self.action_from_wire(value)
      DECISION_ACTIONS.fetch(value, :allow)
    end

    def degraded?
      !!degraded
    end
  end

  # What {Client#identify} recorded, or why it could not.
  #
  # +ok+ is the only field to branch on. When it is false the call changed
  # nothing and +error+ says what happened; the SDK still did not raise.
  #
  # Unlike {Client#track}, identify reports its failures. track has a safe
  # default - retry later - and "I could not record what this customer pays"
  # has none: a wrong plan is a wrong margin.
  IdentifyResult = Struct.new(
    :ok, :customer_id, :plan, :period_start, :period_end, :error,
    keyword_init: true
  ) do
    def ok?
      !!ok
    end
  end

  # The result of the whole guard loop. +kind+ is :completed, :blocked or
  # :topup_required. +result+ is your block's own return value.
  GuardOutcome = Struct.new(:kind, :decision, :result, keyword_init: true) do
    def completed?
      kind == :completed
    end

    def blocked?
      kind == :blocked
    end

    def topup_required?
      kind == :topup_required
    end
  end
end
