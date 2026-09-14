# Promotes a logged DAV exchange to a fixture step: the request the
# client sent, less the headers that identify the tailnet
# (docs/plans/2026-09-13-dav-observability.md, "Every DAV exchange is
# logged locally"). The response is `rake fixtures`'s to write, because
# a response file is a snapshot of this server rather than evidence.

namespace :fixtures do
  desc "Write logged exchange EXCHANGE's request into fixture step directory STEP"
  task :extract do
    require "pathname"
    require "pro_tacts"
    require "pro_tacts/exchange_log"
    require_relative "../test/pro_tacts/exchange_fixtures"

    id = ENV.fetch("EXCHANGE") { abort "EXCHANGE= names the exchange: the id on its log lines and its Sentry exchange tag." }
    step = Pathname.new(ENV.fetch("STEP") { abort "STEP= names the step directory to write, e.g. test/fixtures/ios-exchange/07-delete-contact." })
    request = step / "request"
    abort "#{request} exists. A request file is evidence; delete it first if this exchange supersedes it." if request.exist?

    # The configured log, then rake dev's.
    logs = [ProTacts.config.exchange_log_path, "log/dev.log"].uniq
    head, body = logs.lazy.filter_map { ProTacts::ExchangeLog.read_request(id, it) }.first
    abort "No exchange #{id} in #{logs.join(' or ')}, or their rotations." if head.nil?

    dropped = ExchangeFixtures.write_request(step, head, body)
    puts <<~DONE
      Wrote #{request}, dropping #{dropped.empty? ? 'no headers' : dropped.join(', ')}.
      Run `rake fixtures` to record its response, and review the diff.
    DONE
  end
end
