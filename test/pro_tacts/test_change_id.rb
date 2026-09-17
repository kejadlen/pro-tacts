require_relative "../test_helper"

require "pro_tacts/change_id"

class ChangeIdTest < Minitest::Test
  def test_an_id_is_as_many_letters_from_k_to_z_as_asked_for
    [1, 4, 7, 32].each do |length|
      assert_match(/\A[k-z]{#{length}}\z/, ProTacts::ChangeId.mint(length))
    end
  end

  def test_the_draws_cover_the_whole_alphabet
    assert_equal ProTacts::ChangeId::ALPHABET.sort, ProTacts::ChangeId.mint(1_000).chars.uniq.sort
  end
end
