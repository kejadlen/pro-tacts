# The composition root: everything environment-dependent (data
# directories, Sentry, the access log) happens here rather than at
# require time, so requiring the app has no side effects.
require "pathname"
require "fileutils"
require "sentry-ruby"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts/web"
require "pro_tacts/store"

config = ProTacts.config

# A fresh checkout has no database. Opening it here creates and migrates
# one on this thread, before any request, rather than leaving several
# request threads to race into an empty schema -- and a migration that
# fails takes the deploy down rather than someone's first request.
FileUtils.mkdir_p(config.data_dir)
ProTacts::Web.store = ProTacts::Store.at(config.database_path)

# A nil DSN initializes Sentry but leaves it inert: capture_message
# returns nil and the rack middleware reports nothing.
Sentry.init do |sentry|
  sentry.dsn = config.sentry_dsn

  sentry.breadcrumbs_logger = [:sentry_logger, :http_logger]

  # Off, so no request body, query string, or cookie is sent: a write's
  # body is a card, and card content never leaves the machine. Sentry
  # says that something went wrong; the full exchange stays local
  # (docs/plans/2026-09-13-dav-observability.md).
  sentry.send_default_pii = false

  # Headers are sent regardless, on transactions as well as errors, and
  # the tailnet identity is not worth sending.
  drop_identity = lambda do |event, _hint|
    event.request&.headers&.reject! { |name, _| name.start_with?("Tailscale-User-") }
    event
  end
  sentry.before_send = drop_identity
  sentry.before_send_transaction = drop_identity

  # The debug log is a local-only record of full exchanges, bodies and
  # all. Sentry's sentry_logger hook would otherwise turn every one of
  # its lines into a breadcrumb, and send_default_pii has no say over
  # breadcrumbs. Keyed on the progname DebugLogger#write passes with
  # each line.
  sentry.exclude_loggers = [ProTacts::DebugLogger::PROGNAME]

  sentry.traces_sample_rate = 1.0
end

ProTacts::Web.plugin :common_logger, $stderr

run ProTacts::Web.freeze.app
