require "pathname"
require "rack/test"

require "pro_tacts/tailscale_auth"

# One recorded client exchange: a directory of numbered steps, replayed
# in order. See each directory's README for provenance and the
# request/response file format.
#
# Two clients are recorded, and they are not peers. MACOS is the whole
# working session, the baseline every response change is measured
# against. IOS holds only the steps where iOS sends something macOS
# never did — a different namespace prefix, a header it omits, a verb
# macOS has no equivalent for — so the second replay stays small and
# every step in it is a difference someone can name.
class ExchangeFixtures < Data.define(:directory)
  Step = Data.define(:name, :method, :path, :headers, :body)
  Response = Data.define(:status, :headers, :body)

  FIXTURES = Pathname.new(__dir__).parent / "fixtures"

  # Response headers worth snapshotting; everything else (Content-Length,
  # Date, server) is plumbing.
  RESPONSE_HEADERS = %w[Content-Type ETag DAV Allow Location].freeze

  # Stands in for the Tailscale-User-Login the recorded sessions carried.
  # It was stripped from the request files because it names a real tailnet
  # user; the app now refuses requests without one, so the replay has to
  # put an identity back.
  REPLAY_LOGIN = "replay@example.com"

  # Every recording, for the callers that run all of them.
  def self.all
    [MACOS, IOS]
  end

  def steps
    Dir.children(directory)
      .select { (directory / it).directory? }
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
    }.merge(ProTacts::TailscaleAuth::LOGIN_HEADER => REPLAY_LOGIN)
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
    File.read(directory / name / file)
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
    File.write(directory / step.name / "response", content)
  end
end

ExchangeFixtures::MACOS = ExchangeFixtures.new(ExchangeFixtures::FIXTURES / "macos-exchange")
ExchangeFixtures::IOS = ExchangeFixtures.new(ExchangeFixtures::FIXTURES / "ios-exchange")
