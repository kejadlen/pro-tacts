require "nokogiri"

module ProTacts
  # The XML the DAV routes answer with (web/dav.rb). Each namespace is an
  # object whose methods are the elements this server sends in it, so an
  # element outside them is a NoMethodError, and adding one is a change
  # here — the real decision AGENTS.md says adding a property is.
  module DavXml
    PREFIXES = {
      "d" => "DAV:",
      "card" => "urn:ietf:params:xml:ns:carddav",
      "cs" => "http://calendarserver.org/ns/",
    }.freeze #: Hash[String, String]

    # A whole body under the DAV: element root, declaring "d" and each of
    # prefixes, with the children the block writes. Writing through a
    # namespace left undeclared raises.
    #: (String root, *String prefixes) { (DAV d, CardDAV card, CalendarServer cs) -> void } -> String
    def self.document(root, *prefixes)
      namespaces = ["d", *prefixes].to_h do |prefix|
        ["xmlns:#{prefix}", PREFIXES.fetch(prefix)] #: [String, String]
      end

      Nokogiri::XML::Builder.new(encoding: "UTF-8") { |x|
        x["d"].send(root, namespaces) do
          yield DAV.new(x, "d"), CardDAV.new(x, "card"), CalendarServer.new(x, "cs")
        end
      }.to_xml
    end

    # One namespace's elements. The builder yields itself to an element's
    # block, so `it` inside one is the builder rather than an enclosing
    # block's element.
    class Namespace
      # @rbs @x: Nokogiri::XML::Builder
      # @rbs @prefix: String

      #: (Nokogiri::XML::Builder x, String prefix) -> void
      def initialize(x, prefix)
        @x = x
        @prefix = prefix
      end

      private

      #: (String name, ?String? text) ?{ () -> void } -> void
      def tag(name, text = nil, &)
        element = @x[@prefix]
        text ? element.send(name, text, &) : element.send(name, &)
      end
    end

    class DAV < Namespace
      # A member answered with a 200, holding the properties the block
      # writes.
      #: (String location) { () -> void } -> void
      def found(location, &)
        response do
          href location
          propstat do
            prop(&)
            status "HTTP/1.1 200 OK"
          end
        end
      end

      # A member the collection does not answer for: the multiget miss,
      # reported as a 404 inside the 207 rather than failing the request
      # (RFC 6352 section 8.7), and the removal shape a sync-collection
      # delta reports (RFC 6578 section 3.2 — href and 404, no propstat).
      #: (String location) -> void
      def missing(location)
        response do
          href location
          status "HTTP/1.1 404 Not Found"
        end
      end

      #: () { () -> void } -> void
      def response(&) = tag("response", &)
      #: () { () -> void } -> void
      def propstat(&) = tag("propstat", &)
      #: () { () -> void } -> void
      def prop(&) = tag("prop", &)
      #: (String location) -> void
      def href(location) = tag("href", location)
      #: (String line) -> void
      def status(line) = tag("status", line)

      #: (String etag) -> void
      def getetag(etag) = tag("getetag", etag)
      #: (String token) -> void
      def sync_token(token) = tag("sync-token", token)
      #: () { () -> void } -> void
      def current_user_principal(&) = tag("current-user-principal", &)
      #: () { () -> void } -> void
      def resourcetype(&) = tag("resourcetype", &)
      #: () -> void
      def collection = tag("collection")

      #: () { () -> void } -> void
      def supported_report_set(&) = tag("supported-report-set", &)
      # Also the precondition RFC 3253 section 3.6 names, empty.
      #: () ?{ () -> void } -> void
      def supported_report(&) = tag("supported-report", &)
      #: () { () -> void } -> void
      def report(&) = tag("report", &)
      #: () -> void
      def sync_collection = tag("sync-collection")
      #: () -> void
      def valid_sync_token = tag("valid-sync-token")

      #: () { () -> void } -> void
      def current_user_privilege_set(&) = tag("current-user-privilege-set", &)
      #: () { () -> void } -> void
      def privilege(&) = tag("privilege", &)
      #: () -> void
      def read = tag("read")
      #: () -> void
      def write = tag("write")
      #: () -> void
      def bind = tag("bind")
      #: () -> void
      def unbind = tag("unbind")
    end

    class CardDAV < Namespace
      #: () { () -> void } -> void
      def addressbook_home_set(&) = tag("addressbook-home-set", &)
      #: () -> void
      def addressbook = tag("addressbook")

      # The card's carriage returns go out as character references: a raw
      # CR in text is normalized away by the client's parser (XML 1.0
      # section 2.11), which would hand it LF-only lines.
      #: (String card) -> void
      def address_data(card) = tag("address-data", card)

      # The preconditions of RFC 6352 section 6.3.2.1, each holding what
      # the block writes.
      #: () ?{ () -> void } -> void
      def supported_address_data(&) = tag("supported-address-data", &)
      #: () ?{ () -> void } -> void
      def valid_address_data(&) = tag("valid-address-data", &)
      #: () ?{ () -> void } -> void
      def no_uid_conflict(&) = tag("no-uid-conflict", &)
    end

    class CalendarServer < Namespace
      #: (String ctag) -> void
      def getctag(ctag) = tag("getctag", ctag)
    end
  end
end
