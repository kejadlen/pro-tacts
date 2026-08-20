require "digest"
require "fileutils"
require "pathname"

module ProTacts
  # Keeps a full copy of the requests the app could not answer, so a client
  # asking for something unimplemented leaves behind enough to implement it.
  #
  # Each capture is a directory holding "request" and "response", the same
  # layout and format as test/fixtures/macos-exchange, so promoting one to a
  # fixture is a copy. Strip the identifying headers when you do — captures
  # keep every header, fixtures do not.
  #
  # This is the local counterpart to the Sentry reporting in config.ru, which
  # no longer sends request bodies.
  class UnhandledRequests
    # 404 is the missing-functionality signal: a client asked for something
    # this server does not route. 5xx is kept because Sentry now reports
    # those without a body, and a crash is hard to read without one.
    def self.capture?(status)
      status == 404 || status >= 500
    end

    def initialize(app, directory:)
      @app = app
      @directory = Pathname.new(directory)
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless self.class.capture?(status)

      parts = []
      body.each { parts << it }
      body.close if body.respond_to?(:close)

      capture(env, status, headers, parts.join)

      [status, headers, parts]
    end

    private

    def capture(env, status, headers, body)
      target = @directory / name_for(env)

      # The directory name carries a digest of the request, so an already
      # captured request is one a client is repeating — recording it again
      # would just grow the directory without adding anything.
      return if target.exist?

      FileUtils.mkdir_p(target)
      (target / "request").write(render_request(env))
      (target / "response").write(render_response(status, headers, body))
    rescue SystemCallError => e
      # A failed capture must not turn a 404 into a 500.
      warn "pro-tacts: could not record unhandled request: #{e.message}"
    end

    def name_for(env)
      slug = env["PATH_INFO"].to_s.gsub(%r{[^\w]+}, "-").delete_prefix("-").delete_suffix("-")
      slug = "root" if slug.empty?
      "#{env['REQUEST_METHOD'].to_s.downcase}-#{slug}-#{digest(env)}"
    end

    def digest(env)
      Digest::SHA256.hexdigest([env["REQUEST_METHOD"], env["PATH_INFO"], request_body(env)].join("\n"))[0, 8]
    end

    def render_request(env)
      lines = ["#{env['REQUEST_METHOD']} #{full_path(env)} #{env.fetch('SERVER_PROTOCOL', 'HTTP/1.1')}"]
      lines += each_header(env).map { |name, value| "#{name}: #{value}" }
      message(lines, request_body(env))
    end

    def render_response(status, headers, body)
      message([status.to_s] + headers.map { |name, value| "#{name}: #{value}" }, body)
    end

    def message(lines, body)
      head = lines.join("\n") + "\n\n"
      body = body.to_s.chomp
      body.empty? ? head : "#{head}#{body}\n"
    end

    def full_path(env)
      path = env["PATH_INFO"].to_s
      query = env["QUERY_STRING"].to_s
      query.empty? ? path : "#{path}?#{query}"
    end

    def each_header(env)
      env.filter_map { |key, value|
        case key
        when /\AHTTP_(.+)\z/ then [header_name(Regexp.last_match(1)), value]
        when "CONTENT_TYPE" then ["Content-Type", value]
        when "CONTENT_LENGTH" then ["Content-Length", value]
        end
      }.sort
    end

    def header_name(name)
      name.split("_").map(&:capitalize).join("-")
    end

    def request_body(env)
      input = env["rack.input"]
      return "" if input.nil?

      body = input.read.to_s
      input.rewind
      body
    end
  end
end
