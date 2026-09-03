require_relative "../test_helper"

# ProTacts.silence_warnings, the block helper behind the quiet phlex
# requires: warnings off inside, back on after — including when the
# block raises, which is the half a missing ensure would get wrong
# only when something has already failed.
class ProTactsWarningsTest < Minitest::Test
  def test_silences_warnings_for_the_block_and_restores_them_after
    verbose = $VERBOSE
    ProTacts.silence_warnings { assert_nil $VERBOSE }
    assert_equal verbose, $VERBOSE
  end

  def test_restores_warnings_when_the_block_raises
    verbose = $VERBOSE

    assert_raises(RuntimeError) { ProTacts.silence_warnings { raise "boom" } }

    assert_equal verbose, $VERBOSE
  end
end
