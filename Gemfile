source "https://rubygems.org"

gem "base64"
gem "logger"
gem "nokogiri"
gem "phlex"
gem "puma"
gem "rackup"
gem "rake"
gem "roda"
gem "sentry-ruby"
gem "sequel"
gem "sqlite3"

group :development do
  gem "hegeltest"
  gem "irb"
  gem "minitest"
  gem "rack-test"
  gem "ruby-lsp"
  # Pinned to a prerelease: released Steep parses Ruby as 3.3, where `it`
  # is a method call rather than the block parameter, so every block in
  # lib/ fails to type check. 2.1.0.dev.1 is the first release parsing 3.4.
  gem "steep", "2.1.0.dev.1"
end
