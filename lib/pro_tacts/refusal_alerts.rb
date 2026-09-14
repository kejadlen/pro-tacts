require "rack"
require "sentry-ruby"

require "pro_tacts/exchange_log"

module ProTacts
  # Rack middleware that warns Sentry when a DAV exchange is refused
  # (docs/plans/2026-09-13-dav-observability.md, "Refusals alert"). The
  # warning says only which route refused what; the exchange log, under
  # the id the warning is tagged with, says what was sent.
  class RefusalAlerts
    # @rbs @app: Rack::_App

    # A report this server does not support (403), a resource that is not
    # here (404), a sync token naming a state that is gone (410), and a
    # write whose precondition failed (412), the one status that means a
    # client and this server disagree about a card.
    REFUSALS = [403, 404, 410, 412].freeze #: Array[Integer]

    #: (Rack::_App app) -> void
    def initialize(app)
      @app = app
    end

    # Only an exchange ExchangeLog marked is a DAV one: the admin half
    # reports exceptions and nothing else.
    #: (Rack::env env) -> Rack::response
    def call(env)
      status, headers, body = @app.call(env)
      alert(env, status) if env.key?(ExchangeLog::ENV_KEY) && REFUSALS.include?(status)
      [status, headers, body]
    end

    private

    # Fingerprinted on the route with the card id replaced, so Sentry
    # groups a refusal that repeats across cards as one issue. The id
    # rides as the `card` tag instead, so an issue's events can be
    # searched by card.
    #: (Rack::env env, Integer status) -> void
    def alert(env, status)
      method = env.fetch("REQUEST_METHOD")
      path = env["PATH_INFO"].to_s
      card = path[%r{/([^/]+)\.vcf\z}, 1]
      route = path.sub(%r{/[^/]+\.vcf\z}, "/{id}.vcf")

      Sentry.capture_message(
        "#{method} #{route} answered #{status} #{Rack::Utils::HTTP_STATUS_CODES[status]}",
        level: :warning,
        fingerprint: [method, route, status.to_s],
        tags: card ? { card: } : {},
      )
    end
  end
end
