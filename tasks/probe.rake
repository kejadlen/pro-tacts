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
  # Puts a probe card where a client will sync it. The id is the UID:
  # this server's cards are named by it (see ProTacts::Contact), and a
  # PUT whose body disagrees is refused.
  def seed(id, card)
    require "net/http"
    require "uri"

    # rackup's default, which is what `rake dev` starts.
    url = URI.parse(ENV.fetch("PROBE_URL", "http://localhost:9292"))
    url.path = "/dav/addressbook/#{id}.vcf"

    request = Net::HTTP::Put.new(url)
    request["Content-Type"] = "text/vcard"
    # Serve strips this header from incoming requests and sets it from
    # the tailnet identity, so supplying one is only possible — and only
    # meaningful — against a dev server on localhost
    # (ProTacts::TailscaleAuth).
    request["Tailscale-User-Login"] = ENV.fetch("PROBE_LOGIN", "probe@example.com")
    request.body = card

    response = Net::HTTP.start(url.hostname, url.port) { it.request(request) }
    abort "#{url} answered #{response.code}: #{response.body}" unless response.code.start_with?("2")
    response.code
  end

  # The shared half of every probe's instructions: a successful PUT is
  # not an unhandled request, so the debug log is the only place it
  # lands.
  def reading_the_result(id, name)
    <<~STEPS
      1. The server needs PRO_TACTS_DEBUG=1 for the write to be logged —
         a successful PUT is not an unhandled request, so log/unhandled
         will not have it. Restart with `PRO_TACTS_DEBUG=1 rake dev` if
         it is not set.
      2. Resync the client, edit "#{name}" — any field, the edit itself
         does not matter — and let the write go through.
      3. The PUT body lands in log/dev.log after a `>>` line, under
         #{id}.vcf.
    STEPS
  end

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

  # The follow-up to that one, which answered the companion question
  # with numbering nothing here chose deliberately: item8 and item9,
  # picked to dodge collisions, both got renumbered or stripped, so
  # "the marker does not follow its group" and "the numbering confused
  # the client" were not told apart.
  #
  # This card separates them. Two groups, both spelled the way a client
  # spells its own — dense, in document order, each anchored by an
  # X-ABLabel macOS models — with one gap:
  #
  #   item1  needs no renumbering. If its marker comes back at item1,
  #          an untouched group keeps its companion.
  #   item3  has to move to item2 for the numbering to be dense again.
  #          Its marker either follows the group it belongs to, or it
  #          stays at item3 while the group moves out from under it.
  #
  # The second is the whole experiment: a marker that stays put is a
  # binding the client never maintained, and one that follows is a
  # binding provenance could rest on. The first is the control that
  # says the card was well-formed enough to be kept at all.
  RENUMBER_ID = "probe-renumber"
  RENUMBER_CARD = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Boole;Renumber;;;
    FN:Probe Renumber
    item1.TEL;TYPE=cell:+44 20 5555 0100
    item1.X-ABLabel:household
    item1.X-PT-GROUP:kxsv
    item3.EMAIL;TYPE=internet:probe@example.com
    item3.X-ABLabel:household
    item3.X-PT-GROUP:mnop
    UID:#{RENUMBER_ID}
    END:VCARD
  CARD

  desc "Seed the annotation probe card into a running dev server (PROBE_URL to override)"
  task :annotations do
    code = seed(PROBE_ID, PROBE_CARD)

    puts <<~NEXT
      Seeded #{PROBE_ID} (#{code}).

      #{reading_the_result(PROBE_ID, "Probe Boole").chomp}
      4. Compare it with the card in tasks/probe.rake: which of the five
         forms came back, whether itemN was renumbered, and whether a
         companion stayed with the line it was grouped with.
      5. Record what happened in docs/macos-contacts.md. Repeat on iOS,
         which numbers item groups differently (see
         test/fixtures/ios-exchange/05-put-contact-edit/request).
    NEXT
  end

  desc "Seed the renumbering probe: does a companion follow its group?"
  task :renumber do
    code = seed(RENUMBER_ID, RENUMBER_CARD)

    puts <<~NEXT
      Seeded #{RENUMBER_ID} (#{code}).

      #{reading_the_result(RENUMBER_ID, "Probe Renumber").chomp}
      4. Read the two groups that come back:
         - item1.TEL and its X-ABLabel should not have to move. Did
           item1.X-PT-GROUP come back beside them?
         - item3.EMAIL and its X-ABLabel should land on item2. Did
           item3.X-PT-GROUP follow them there, or stay at item3?
         The second answers whether a companion is a binding the client
         maintains or two numbers that happened to agree.
      5. Record what happened in docs/macos-contacts.md, under "An
         annotation survives only on its own line".
    NEXT
  end
end
