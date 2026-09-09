# Probes for client behavior this server cannot reason its way to. A
# probe is a card built to be edited by a real client and read back off
# the wire, because what Apple does with a property is empirical and
# every guess about it has been wrong at least once
# (docs/macos-contacts.md).
#
# Seeded over HTTP rather than into the database, so the card travels
# the same route a client's would and the dev server needs no
# cooperation beyond running.

namespace :probe do
  # The annotation forms under test, one card so a single edit answers
  # all five. Each is independent: whatever the client keeps, drops, or
  # renumbers, it does to each of these on its own terms.
  #
  #   X-PT-GROUP            a standalone unmodeled property — the
  #                         control, and the only form with prior
  #                         evidence, since macOS writes X- properties
  #                         of its own (X-ADDRESSING-GRAMMAR)
  #   ADR;X-PT-GROUP=       an unknown parameter on a property whose
  #                         parameter section macOS rebuilds from its
  #                         own model — the form the plan assumed and
  #                         the one most likely to be lost
  #   NOTE;X-PT-GROUP=      the same on a property macOS has not been
  #                         seen to re-parameterize
  #   item9.X-PT-GROUP      a companion line in a property group with
  #                         no label the client models
  #   item8.X-PT-GROUP      a companion beside an X-ABLabel that it
  #                         does, in case the known line is what
  #                         anchors the group through a renumber
  #
  # The id is the UID: this server's cards are named by it (see
  # ProTacts::Contact), and a PUT whose body disagrees is refused.
  PROBE_ID = "probe-annotations"
  PROBE_CARD = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Boole;Probe;;;
    FN:Probe Boole
    X-PT-GROUP:kxsv
    ADR;TYPE=home;X-PT-GROUP=kxsv:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom
    NOTE;X-PT-GROUP=kxsv:Gate code 1854.
    item9.ADR;TYPE=work:;;1 Long Road;London;England;NW1 1AB;United Kingdom
    item9.X-PT-GROUP:kxsv
    item8.TEL;TYPE=cell:+44 20 5555 0100
    item8.X-ABLabel:household
    item8.X-PT-GROUP:kxsv
    UID:#{PROBE_ID}
    END:VCARD
  CARD

  desc "Seed the annotation probe card into a running dev server (PROBE_URL to override)"
  task :annotations do
    require "net/http"
    require "uri"

    # rackup's default, which is what `rake dev` starts.
    url = URI.parse(ENV.fetch("PROBE_URL", "http://localhost:9292"))
    url.path = "/dav/addressbook/#{PROBE_ID}.vcf"

    request = Net::HTTP::Put.new(url)
    request["Content-Type"] = "text/vcard"
    # Serve strips this header from incoming requests and sets it from
    # the tailnet identity, so supplying one is only possible — and only
    # meaningful — against a dev server on localhost
    # (ProTacts::TailscaleAuth).
    request["Tailscale-User-Login"] = ENV.fetch("PROBE_LOGIN", "probe@example.com")
    request.body = PROBE_CARD

    response = Net::HTTP.start(url.hostname, url.port) { it.request(request) }
    abort "#{url} answered #{response.code}: #{response.body}" unless response.code.start_with?("2")

    puts <<~NEXT
      Seeded #{PROBE_ID} (#{response.code}).

      1. The server needs PRO_TACTS_DEBUG=1 for the write to be logged —
         a successful PUT is not an unhandled request, so log/unhandled
         will not have it. Restart with `PRO_TACTS_DEBUG=1 rake dev` if
         it is not set.
      2. Resync the client, edit "Probe Boole" — any field, the edit
         itself does not matter — and let the write go through.
      3. The PUT body lands in log/dev.log after a `>>` line. Compare it
         with the card above: which of the five forms came back, whether
         itemN was renumbered, and whether a companion stayed with the
         line it was grouped with.
      4. Record what happened in docs/macos-contacts.md. Repeat on iOS,
         which numbers item groups differently (see
         test/fixtures/ios-exchange/05-put-contact-edit/request).
    NEXT
  end
end
