require_relative "../test_helper"

require "pro_tacts/proxy_auth"

# What the header says. That a request naming nobody is refused, and how,
# is Web's (see WebTest).
class ProxyAuthTest < Minitest::Test
  def login(value = "alpha@example.com", sent_as: "HTTP_REMOTE_USER")
    env = {} #: Hash[String, String]
    env[sent_as] = value unless value.nil?
    ProTacts::ProxyAuth.login(env)
  end

  def test_the_header_is_the_login
    assert_equal "alpha@example.com", login
  end

  def test_no_header_is_nobody
    assert_nil login(nil)
  end

  def test_an_empty_login_is_nobody
    assert_nil login("")
  end

  def test_a_blank_login_is_nobody
    assert_nil login("   ")
  end

  def test_a_login_on_another_header_is_nobody
    assert_nil login(sent_as: "HTTP_TAILSCALE_USER_LOGIN")
  end

  # The proxy copies the value through, so a non-ASCII one arrives as the
  # UTF-8 it was written in rather than MIME-encoded.
  def test_a_non_ascii_login_is_read_as_utf8
    assert_equal "zoë@example.com", login((+"zoë@example.com").force_encoding(Encoding::BINARY))
  end

  def test_a_login_that_is_not_utf8_is_nobody
    assert_nil login((+"zo\xEB").force_encoding(Encoding::BINARY))
  end
end
