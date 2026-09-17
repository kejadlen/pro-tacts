require "net/http"

require "pro_tacts/import/execute"

module ProTacts
  module Import
    # A host over one started connection. The identity header is the
    # host's proxy to write, so nothing here sets one.
    class HttpClient
      # @rbs @http: Net::HTTP

      #: (Net::HTTP http) -> void
      def initialize(http)
        @http = http
      end

      #: (String method, String path, ?headers: Hash[String, String], ?body: String?) -> Execute::Response
      def call(method, path, headers: {}, body: nil)
        response = @http.send_request(method, path, body, headers)
        Execute::Response.new(status: response.code.to_i, headers: response.to_hash.transform_values { it.join(", ") }, body: response.body.to_s)
      end
    end
  end
end
