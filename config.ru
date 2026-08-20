# The composition root: everything environment-dependent (data
# directories, Sentry, the access log) happens here rather than at
# require time, so requiring the app has no side effects.
require "pathname"
require "fileutils"
require "sentry-ruby"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts/web"

config = ProTacts.config

# A fresh checkout has no contacts dir; an empty address book beats a
# 500 on every request.
FileUtils.mkdir_p(config.contacts_dir)

# A nil DSN initializes Sentry but leaves it inert: capture_message
# returns nil and the rack middleware reports nothing.
Sentry.init do |sentry|
  sentry.dsn = config.sentry_dsn

  # Get breadcrumbs from logs
  sentry.breadcrumbs_logger = [:sentry_logger, :http_logger]

  # Off keeps the request body, query string, cookies, and client IP out of
  # events. None of that is sensitive today: a read-only server's request
  # bodies carry opaque contact UIDs, not card content, and the IPs are
  # tailnet addresses. It is off because log/unhandled keeps the same bodies
  # in better shape (see ProTacts::UnhandledRequests), and because a write
  # path would put whole vCards in them. Headers still go, including
  # Tailscale-User-Login, which says who hit the 404.
  sentry.send_default_pii = false

  # Trace all the things!
  sentry.traces_sample_rate = 1.0
end

ProTacts::Web.plugin :common_logger, $stderr

run ProTacts::Web.freeze.app
