require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/rack"
require "sentry-ruby"
require "sentry-opentelemetry"

module ProTacts
  # Tracing runs on OpenTelemetry, which hands every span to Sentry and,
  # when an endpoint is configured, to an OTLP collector such as
  # VictoriaTraces. Sentry's own instrumentation is off (config.ru's
  # instrumenter), so its transactions are built from these spans.
  module Tracing
    # A proxy until configure installs the SDK, which it then delegates to,
    # so the app can hold it from require time.
    TRACER = OpenTelemetry.tracer_provider.tracer("pro_tacts") #: OpenTelemetry::Trace::Tracer

    # The statuses whose transactions Sentry drops: sentry-ruby's default
    # (TRACE_IGNORE_STATUS_CODES_DEFAULT) less 303, which answers every
    # admin write, so an upload or a Save is traced. Applied by scrub,
    # because Sentry's trace_ignore_status_codes never sees the status of
    # a span it did not start.
    UNTRACED_STATUSES = [(301..302), (305..399), (401..404)].freeze #: Array[Range[Integer]]

    #: (String? endpoint) -> void
    def self.configure(endpoint)
      OpenTelemetry::SDK.configure do |otel|
        otel.service_name = "pro-tacts"
        # Named by route rather than the method alone, which would make
        # every request one Sentry transaction. PATH_INFO, not the request
        # URI the instrumentation offers, so the name carries no query.
        otel.use "OpenTelemetry::Instrumentation::Rack",
          url_quantization: ->(_uri, env) { "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}" }
        otel.add_span_processor(Sentry::OpenTelemetry::SpanProcessor.instance)
        if endpoint
          exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint:)
          otel.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
        end
      end
      OpenTelemetry.propagation = Sentry::OpenTelemetry::Propagator.new
    end

    # The request span's middleware, for the outside of the app's stack.
    #: () -> Array[untyped]
    def self.middleware
      OpenTelemetry::Instrumentation::Rack::Instrumentation.instance.middleware_args
    end

    # For before_send_transaction. Sentry copies every attribute of the
    # request span into the transaction's otel context, which
    # send_default_pii does not reach, so the query string goes here.
    #: (Sentry::TransactionEvent event) -> Sentry::TransactionEvent?
    def self.scrub(event)
      otel = event.contexts[:otel]
      attributes = otel&.[](:attributes)
      return event unless otel && attributes

      status = attributes["http.response.status_code"]
      return if status.is_a?(Integer) && UNTRACED_STATUSES.any? { it.cover?(status) }

      # A finished span's attributes are frozen.
      otel[:attributes] = attributes.except("url.query")
      event
    end
  end
end
