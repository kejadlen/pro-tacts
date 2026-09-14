
# A throwaway data directory holds the database the tests run against,
# seeded from test/fixtures/cards so the recorded macOS exchange resolves
# the same hrefs the real client did. Every run builds its own tmpdirs,
# so nothing survives a run and two runs cannot collide.
#
# Cleanup runs through Minitest.after_run, not a plain at_exit: minitest
# 6's autorun nests one at_exit inside another and runs the tests inside
# the outer handler, so an at_exit registered after minitest/autorun —
# which the TestTask command and several test files require first —
# would fire BEFORE the tests and delete the database mid-suite.
#
# The environment is set before the app is required rather than after it,
# so the requires cannot all sit at the top: the app reads configuration
# as it loads, because the exchange log is given its path at
# class-definition time. Set it afterwards and the failed exchanges land
# in log/ instead of the tmpdir.
require "fileutils"
require "minitest"
require "pathname"
require "tmpdir"

data_dir = Pathname.new(Dir.mktmpdir("pro-tacts-test"))
ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
Minitest.after_run { FileUtils.remove_entry(data_dir) }

# Several tests provoke failed exchanges. Their log goes with the run
# unless PRO_TACTS_EXCHANGE_LOG is exported to keep it, and stays out of
# log/exchange.log, which is for real client sessions only.
exchange_dir = Pathname.new(Dir.mktmpdir("pro-tacts-exchanges"))
ENV["PRO_TACTS_EXCHANGE_LOG"] ||= (exchange_dir / "exchange.log").to_s
Minitest.after_run { FileUtils.remove_entry(exchange_dir) }

require_relative "fixture_data"
require "pro_tacts/web"
require "sentry-ruby"
require "sentry/test_helper"

# Sentry is initialized here rather than left dormant because the gem's
# test helper builds on an initialized SDK. The DSN is forced nil rather
# than read from the environment, so a real SENTRY_DSN in this shell
# cannot point a test run at a live project. init also registers
# at_exit { close }, and the suite's runner requires minitest/autorun
# before any of this loads — so Sentry's close fires before minitest's
# at_exit runs the tests, and setup (SentryMessages#setup_sentry)
# re-opens the SDK when it finds it closed. Before minitest/autorun
# regardless, per the rule the header states, so direct single-file
# runs — where this file is the entry — keep the close after the tests.
Sentry.init { |sentry| sentry.dsn = nil }

require "minitest/autorun"

# Standing in for config.ru, which never runs here: build the store and
# hand it to the app.
ProTacts::Web.store = FixtureData.install(data_dir)

# The helper's other half: setup_sentry_test re-points the SDK at a
# dummy DSN and a recording transport, so what the app reports is
# observable in sentry_events without anything being sent and without
# redefining Sentry.capture_message. This suite's assertions read
# report texts, so the recorded Sentry::ErrorEvents also become the
# message strings, in capture order. Shared by the two test classes
# whose layers report — the web's PUT a broken parser assumption, the
# store its birthday model what it cannot recompose.
module SentryMessages
  def setup_sentry
    Sentry.init { |sentry| sentry.dsn = nil } unless Sentry.initialized?
    setup_sentry_test
  end

  def sentry_messages
    sentry_events.map { it.message }
  end
end

# Hands the app a throwaway store holding just the given cards (id to
# bytes), so a route can be exercised without touching the fixture
# book, and yields it so a test can change a card mid-sequence. Only
# the store is swapped: nothing in a request reads configuration.
module ThrowawayContacts
  def with_contacts(cards)
    Dir.mktmpdir do |dir|
      original = ProTacts::Web.store

      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        ProTacts::Web.store = store
        cards.each do |id, card|
          store.put(id, ProTacts::VCard.new(card))
        end
        yield store
      ensure
        ProTacts::Web.store = original
      end
    end
  end

  # A card as Contacts would send one, so the routes are exercised
  # against stored bytes rather than anything a test renders.
  def card(id, name)
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\nUID:#{id}\r\nEND:VCARD\r\n"
  end
end
