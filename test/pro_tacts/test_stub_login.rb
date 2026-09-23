require_relative "../test_helper"

require "pro_tacts/stub_login"

class StubLoginTest < Minitest::Test
  def login_seen(env = {})
    seen = nil
    app = ->(inner) { seen = ProTacts::ProxyAuth.login(inner); [200, {}, []] }
    ProTacts::StubLogin.new(app).call(env)
    seen
  end

  def test_a_request_with_no_login_gets_the_stand_in
    assert_equal "alpha@example.com", login_seen
  end

  def test_a_request_naming_a_login_keeps_it
    assert_equal "zoe@example.com", login_seen("HTTP_REMOTE_USER" => "zoe@example.com")
  end
end
