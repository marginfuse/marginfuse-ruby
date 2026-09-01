# frozen_string_literal: true

require_relative "marginfuse/version"
require_relative "marginfuse/types"
require_relative "marginfuse/client"
require_relative "marginfuse/open_router"

# MarginFuse: profitability guardrails for AI SaaS.
#
# Server side only: the SDK carries a secret API key.
module MarginFuse
  # Convenience for the common case.
  #
  #   mf = MarginFuse.new(api_key: ENV.fetch("MARGINFUSE_KEY"))
  def self.new(**)
    Client.new(**)
  end
end
