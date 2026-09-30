require_relative "../../test_helper"

require "rack/test"

require "pro_tacts"
require "pro_tacts/config"
require "pro_tacts/web"

# The shell — header and footer — exercised through /setup: it is the
# one screen that renders the layout without a store behind it, and
# both bars are the layout's, so what holds here holds on every screen.
class AdminLayoutTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Remote-User", "test@example.com"
    @config = ProTacts.config
  end

  def teardown
    ProTacts.config = @config
  end

  def with_env(env)
    ProTacts.config = ProTacts::Config.new(env)
    get "/setup"
  end

  # Everything above the fold, before the screen's own content starts.
  #: () -> String
  def header_html
    last_response.body.split("<main").first
  end

  def test_the_header_names_who_is_logged_in
    with_env({})

    assert_includes header_html, "test@example.com"
  end

  def test_the_account_menu_opens_on_the_login
    with_env({})

    assert_includes header_html, %(popovertarget="user-menu")
    assert_includes header_html, %(<ul id="user-menu" popover="auto")
  end

  # The search is a button in the header and the dialog it opens
  # (Admin::SearchDialog), rendered on every screen, beside the link a
  # phone shows instead (admin.css picks one per width). rack-test
  # cannot open a popover or run the fetch, so this pins the wiring a
  # browser acts on: the declarative pair, the link, the input focused
  # as the dialog opens, the route its results come from, and the key
  # that opens it.
  def test_the_search_is_a_button_and_the_dialog_it_opens
    with_env({})

    assert_includes header_html, %(<button type="button" class="search-button" data-size="sm" popovertarget="search">)
    assert_includes header_html, %(<a href="/search" class="icon-button phone-glyph" aria-label="Search">)
    assert_includes header_html, %(<dialog id="search" popover="auto" class="search-dialog")
    assert_includes header_html, %(<input type="search" name="q" value="" placeholder="Search contacts" aria-label="Search contacts" autofocus)
    assert_includes header_html, "fetch('/search/results?q='"
    assert_includes header_html, "@keydown.slash.window"
    assert_includes header_html, %(aria-label="Clear search")
  end

  # On a phone the name and the nav are hidden and the menu carries
  # home and the destinations instead (admin.css), so both have to
  # be there.
  def test_the_account_menu_repeats_the_destinations
    with_env({})

    assert_includes header_html, %(<li class="menu-nav"><a href="/">home</a></li>)
    assert_includes header_html, %(<li class="menu-nav"><a href="/contacts">contacts</a></li>)
    assert_includes header_html, %(<li class="menu-nav"><a href="/groups">groups</a></li>)
  end

  def test_the_account_menu_links_to_the_import_screen
    with_env({})

    assert_includes header_html, %(<a href="/import">import</a>)
  end

  # The menu's one link that is not a screen: the whole book out as
  # a file, import's counterpart.
  def test_the_account_menu_links_to_the_export
    with_env({})

    assert_includes header_html, %(<a href="/contacts/export.vcf">export</a>)
  end

  def test_the_account_menu_links_to_device_setup
    with_env({})

    assert_includes header_html, %(<a href="/setup">device setup</a>)
  end

  def test_the_footer_names_the_version_the_image_carries
    with_env("VERSION" => "20260904-1822-a1b2c3d")

    assert_includes last_response.body, "20260904-1822-a1b2c3d"
  end

  # Blank is what an image built by hand says (see Config#version): the
  # Dockerfile sets the variable from a build arg that was never passed,
  # so it arrives empty rather than absent. Either way there is no
  # version to name, and the footer does not invent one — but the bar
  # itself stays, the frame's other edge.
  def test_an_unversioned_run_names_no_version
    with_env("VERSION" => "")

    assert_includes last_response.body, %(<footer class="admin-footer"></footer>)

    with_env({})

    assert_includes last_response.body, %(<footer class="admin-footer"></footer>)
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

  def test_a_configured_accent_marks_the_page
    with_env("PRO_TACTS_ACCENT" => "ink-blue")

    assert_includes last_response.body, %(<html lang="en" data-accent="ink-blue">)
  end

  def test_no_accent_leaves_the_page_unmarked
    with_env({})

    assert_includes last_response.body, %(<html lang="en">)
  end

  def test_the_tab_carries_the_configured_favicon
    with_env("PRO_TACTS_FAVICON" => "/favicon-dev.svg")

    assert_includes last_response.body, %(<link rel="icon" href="/favicon-dev.svg">)
  end

  def test_no_favicon_leaves_the_tab_bare
    with_env({})

    refute_includes last_response.body, %(rel="icon")
  end

  def test_the_title_names_the_instance
    with_env({})

    assert_includes last_response.body, "<title>pro-tacts — Device setup</title>"

    with_env("PRO_TACTS_INSTANCE_NAME" => "pro-tacts (dev)")

    assert_includes last_response.body, "<title>pro-tacts (dev) — Device setup</title>"
  end
end
