
require "pathname"
require "rack/test"

# Loads and replays the recorded macOS Contacts exchange in
# test/fixtures/macos-exchange. See that directory's README for provenance
# and the request/response file format.
module ExchangeFixtures
  DIRECTORY = Pathname.new(__dir__).parent / "fixtures" / "macos-exchange"

  Step = Struct.new(:name, :method, :path, :headers, :body, keyword_init: true)
  Response = Struct.new(:status, :headers, :body, keyword_init: true)

  # Response headers worth snapshotting; everything else (Content-Length,
  # Date, server) is plumbing.
  RESPONSE_HEADERS = %w[Content-Type ETag DAV Allow Location].freeze

  class << self
    def steps
      Dir.children(DIRECTORY)
        .select { (DIRECTORY / it).directory? }
        .sort
        .map { |name| Step.new(name:, **parse_request(name)) }
    end

    def parse_request(name)
      request_line, header_lines, body = split_message(read(name, "request"))
      method, path, = request_line.split(" ")
      { method:, path:, headers: parse_headers(header_lines), body: }
    end

    def recorded_response(step)
      status_line, header_lines, body = split_message(read(step.name, "response"))
      Response.new(status: status_line.to_i, headers: parse_headers(header_lines), body:)
    end

    # Rack env for the recorded headers: Content-Type and Depth are the only
    # ones the app reads, but replaying all of them keeps the fidelity.
    def env_for(step)
      step.headers.to_h { |name, value|
        key = name == "Content-Type" ? "CONTENT_TYPE" : "HTTP_#{name.tr('-', '_').upcase}"
        [key, value]
      }
    end

    # Replays every recorded request against the app and rewrites the
    # response fixtures. Rake task "fixtures"; run it after deliberately
    # changing responses, and review the diff.
    def record_responses(app)
      session = Rack::Test::Session.new(Rack::MockSession.new(app))
      steps.each do |step|
        session.request(step.path, { method: step.method, input: step.body }.merge(env_for(step)))
        write_response(step, session.last_response)
      end
    end

    private

    def read(name, file)
      File.read(DIRECTORY / name / file)
    end

    def split_message(raw)
      head, body = raw.split("\n\n", 2)
      lines = head.split("\n")
      [lines.first, lines.drop(1), body.to_s.chomp]
    end

    def parse_headers(lines)
      lines.to_h { |line| line.split(": ", 2) }
    end

    def write_response(step, response)
      headers = RESPONSE_HEADERS
        .filter_map { |name| response[name] && "#{name}: #{response[name]}" }
      content = ([response.status.to_s] + headers).join("\n") + "\n\n"
      body = response.body.chomp
      content = "#{content}#{body}\n" unless body.empty?
      File.write(DIRECTORY / step.name / "response", content)
    end
  end
end
