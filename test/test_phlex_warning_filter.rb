require_relative "test_helper"

# The path predicate behind the Warning.warn override in test_helper:
# phlex's install directory and nothing else. The trailing slash in the
# comparison is what keeps a hypothetical neighboring gem (a phlex-foo,
# installed beside phlex) from matching on prefix alone. The override's
# wiring is not asserted here — calling Warning.warn from a test would
# print the very warnings this suite suppresses — so the wiring is
# verified by the test run's own output instead.
class PhlexWarningFilterTest < Minitest::Test
  def test_matches_only_messages_from_phlex_install_path
    phlex = "#{PhlexWarningFilter::PHLEX_PATH}/lib/phlex/html.rb:84: " \
      "warning: mismatched indentations at 'elsif' with 'if' at 58"
    assert PhlexWarningFilter.from_phlex?(phlex)

    app = "test/pro_tacts/test_store.rb:626: warning: ambiguous `/`"
    refute PhlexWarningFilter.from_phlex?(app)
  end
end
