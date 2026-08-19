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

  # Add data like request headers and IP for users, if applicable;
  # see https://docs.sentry.io/platforms/ruby/data-management/data-collected/ for more info
  sentry.send_default_pii = true

  # Trace all the things!
  sentry.traces_sample_rate = 1.0
end

ProTacts::Web.plugin :common_logger, $stderr

run ProTacts::Web.freeze.app
