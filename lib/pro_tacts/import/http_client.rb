require "net/http"

module ProTacts
  module Import
    # A host over one started connection, which is how `finalize` asks
    # whether a card it is about to delete from the Mac is still on the
    # server it landed on. The identity header is the host's proxy to
    # write, so nothing here sets one.
    class HttpClient
      # @rbs @http: Net::HTTP

      # What a host answered. It lives here rather than beside the
      # caller because the caller is now whoever holds a client: it
      # was Execute's, and Execute is the import screen
      # (docs/plans/2026-09-20-import-by-upload.md). Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Response = Data.define(:status, :headers, :body)

      #: (Net::HTTP http) -> void
      def initialize(http)
        @http = http
      end

      #: (String method, String path, ?headers: Hash[String, String], ?body: String?) -> Response
      def call(method, path, headers: {}, body: nil)
        response = @http.send_request(method, path, body, headers)
        Response.new(status: response.code.to_i, headers: response.to_hash.transform_values { it.join(", ") }, body: response.body.to_s)
      end
    end
  end
end
