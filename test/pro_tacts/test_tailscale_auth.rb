require_relative "../test_helper"

require "pro_tacts/tailscale_auth"

# What the headers say. That a request naming nobody is refused, and how,
# is Web's (see WebTest).
class TailscaleAuthTest < Minitest::Test
  def identity(login: "alpha@example.com", name: "Alpha Chen")
    env = {} #: Hash[String, String]
    env[ProTacts::TailscaleAuth::LOGIN_HEADER] = login unless login.nil?
    env[ProTacts::TailscaleAuth::NAME_HEADER] = name unless name.nil?
    ProTacts::TailscaleAuth.identity(env)
  end

  def test_both_headers_are_the_identity
    assert_equal ProTacts::TailscaleAuth::Identity.new(login: "alpha@example.com", name: "Alpha Chen"), identity
  end

  def test_no_headers_are_nobody
    assert_nil identity(login: nil, name: nil)
  end

  def test_an_empty_login_is_nobody
    assert_nil identity(login: "")
  end

  def test_a_blank_login_is_nobody
    assert_nil identity(login: "   ")
  end

  def test_a_missing_name_is_nobody
    assert_nil identity(name: nil)
  end

  def test_a_blank_name_is_nobody
    assert_nil identity(name: "   ")
  end

  # What Go's mime.QEncoding writes for a non-ASCII value, which is how
  # serve sends one.
  def test_a_q_encoded_name_is_decoded
    assert_equal "Zoë Chen", identity(name: "=?utf-8?q?Zo=C3=AB_Chen?=").name
  end

  def test_a_q_encoded_login_is_decoded
    assert_equal "zoë@example.com", identity(login: "=?utf-8?q?zo=C3=AB@example.com?=").login
  end

  def test_whitespace_between_encoded_words_is_dropped
    assert_equal "Zoë Chen", identity(name: "=?utf-8?q?Zo=C3=AB?= =?utf-8?q?_Chen?=").name
  end

  def test_whitespace_around_plain_text_is_kept
    assert_equal "Dr Zoë Chen", identity(name: "Dr =?utf-8?q?Zo=C3=AB?= Chen").name
  end

  def test_a_b_encoded_name_is_decoded
    assert_equal "Zoë Chen", identity(name: "=?UTF-8?B?Wm/DqyBDaGVu?=").name
  end

  def test_a_name_in_another_charset_is_nobody
    assert_nil identity(name: "=?iso-8859-1?q?Zo=EB?=")
  end

  def test_a_name_that_decodes_to_invalid_utf8_is_nobody
    assert_nil identity(name: "=?utf-8?q?Zo=EB?=")
  end

  def test_a_malformed_b_word_is_nobody
    assert_nil identity(name: "=?utf-8?b?not*base64?=")
  end
end
