require_relative "../../test_helper"

require "rack/test"

require "pro_tacts"
require "pro_tacts/config"
require "pro_tacts/web"

# The shell's footer, exercised through /setup: it is the one screen
# that renders the layout without a store behind it, and the footer is
# the layout's, so what holds here holds on every screen.
class AdminFooterTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Tailscale-User-Login", "test@example.com"
    @config = ProTacts.config
  end

  def teardown
    ProTacts.config = @config
  end

  def with_env(env)
    ProTacts.config = ProTacts::Config.new(env)
    get "/setup"
  end

  def test_the_footer_links_to_device_setup
    with_env({})

    assert_includes last_response.body, %(<a href="/setup" class="type-label">device setup</a>)
  end

  def test_the_footer_names_the_version_the_image_carries
    with_env("VERSION" => "20260904-1822-a1b2c3d")

    assert_includes last_response.body, "20260904-1822-a1b2c3d"
  end

  # Blank is what an image built by hand says (see Config#version): the
  # Dockerfile sets the variable from a build arg that was never passed,
  # so it arrives empty rather than absent. Either way there is no
  # release behind the screen, which is the thing to say.
  def test_an_unversioned_run_says_it_is_the_dev_server
    with_env("VERSION" => "")

    assert_includes last_response.body, "dev server"

    with_env({})

    assert_includes last_response.body, "dev server"
  end

  # The label is a standing notice, not a status: the log is recording
  # whole requests, contact data included, for as long as it is up. It
  # reads as a flag on the build, which is what it is.
  def test_debug_logging_says_so_while_it_is_on
    with_env("PRO_TACTS_DEBUG" => "1")

    assert_includes last_response.body, "+debug"
  end

  def test_the_quiet_case_is_silent
    with_env({})

    refute_includes last_response.body, "+debug"
  end
end
