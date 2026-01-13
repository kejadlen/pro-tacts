# frozen_string_literal: true

require "sentry-ruby"
use Sentry::Rack::CaptureExceptions

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "pro_tacts/web"

run ProTacts::Web.freeze.app
