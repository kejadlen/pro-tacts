# frozen_string_literal: true

module ProTacts
  # Whether debug logging is on. When true, every request and response is
  # dumped in full — headers and bodies on both sides. Off by default because
  # it logs contact data; see ProTacts::DebugLogger.
  def self.debug_logging?
    value = ENV["PRO_TACTS_DEBUG"]
    !value.nil? && value.match?(/\A(1|true|yes)\z/i)
  end
end
