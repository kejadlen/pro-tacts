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

  def test_a_minted_contact_id_is_twelve_letters_from_the_alphabet
    assert ProTacts::ChangeId.minted?(ProTacts::ChangeId.mint(ProTacts::ChangeId::CONTACT_LENGTH))
  end

  def test_a_client_uuid_is_not_a_minted_contact_id
    refute ProTacts::ChangeId.minted?("AB12C345-6789-0DEF-1234-567890ABCDEF")
  end

  def test_a_group_id_is_not_a_minted_contact_id
    refute ProTacts::ChangeId.minted?(ProTacts::ChangeId.mint(4))
  end

  def test_letters_outside_the_alphabet_are_not_minted
    refute ProTacts::ChangeId.minted?("abcdefghijjj")
  end
end
