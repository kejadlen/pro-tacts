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

  # What Go's mime.QEncoding writes for a non-ASCII value, which is how
  # serve sends one.
  def test_a_q_encoded_login_is_decoded
    assert_equal "zoë@example.com", login("=?utf-8?q?zo=C3=AB@example.com?=")
  end

  def test_whitespace_between_encoded_words_is_dropped
    assert_equal "Zoë Chen", login("=?utf-8?q?Zo=C3=AB?= =?utf-8?q?_Chen?=")
  end

  def test_whitespace_around_plain_text_is_kept
    assert_equal "Dr Zoë Chen", login("Dr =?utf-8?q?Zo=C3=AB?= Chen")
  end

  def test_a_b_encoded_login_is_decoded
    assert_equal "Zoë Chen", login("=?UTF-8?B?Wm/DqyBDaGVu?=")
  end

  def test_a_login_in_another_charset_is_nobody
    assert_nil login("=?iso-8859-1?q?Zo=EB?=")
  end

  def test_a_login_that_decodes_to_invalid_utf8_is_nobody
    assert_nil login("=?utf-8?q?Zo=EB?=")
  end

  def test_a_malformed_b_word_is_nobody
    assert_nil login("=?utf-8?b?not*base64?=")
  end
end
