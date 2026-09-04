# The composition root: everything environment-dependent (data
# directories, Sentry, the access log) happens here rather than at
# require time, so requiring the app has no side effects.
require "pathname"
require "fileutils"
require "sentry-ruby"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts/web"
require "pro_tacts/sentry_scrubber"
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

  # On: request bodies are worth having on a 404, and nothing else this
  # sends is sensitive. Hrefs carry opaque contact UIDs, not names, and the
  # IPs are tailnet addresses.
  sentry.send_default_pii = true

  # The one thing that must not leave the machine is card content, which a
  # write path would put directly in a PUT body. Full bodies are kept
  # locally either way, see ProTacts::UnhandledRequests.
  sentry.before_send = ProTacts::SentryScrubber

  # The debug log is a local-only record of full exchanges, bodies and
  # all. Sentry's sentry_logger hook would otherwise turn every one of
  # its lines into a breadcrumb, and breadcrumbs reach Sentry without
  # passing the scrubber above. Keyed on the progname DebugLogger#write
  # passes with each line.
  sentry.exclude_loggers = [ProTacts::DebugLogger::PROGNAME]

  sentry.traces_sample_rate = 1.0
end

ProTacts::Web.plugin :common_logger, $stderr

run ProTacts::Web.freeze.app
