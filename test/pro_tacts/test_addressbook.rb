require_relative "../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/addressbook"

class AddressbookTest < Minitest::Test
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      contacts_dir = Pathname.new(dir) / "contacts"
      Dir.mkdir(contacts_dir)
      files.each { |name, content| File.write(contacts_dir / name, content) }
      yield contacts_dir
    end
  end

  def ctag(contacts_dir)
    ProTacts::Addressbook.load(contacts_dir).ctag
  end

  def test_the_ctag_is_stable_across_loads
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do |contacts_dir|
      assert_equal ctag(contacts_dir), ctag(contacts_dir)
    end
  end

  def test_the_ctag_moves_with_a_cards_content
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do |contacts_dir|
      before = ctag(contacts_dir)
      File.write(contacts_dir / "aiden.kdl", "name \"Aiden Smith\"")

      refute_equal before, ctag(contacts_dir)
    end
  end

  def test_the_ctag_moves_with_membership_both_ways
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do |contacts_dir|
      alone = ctag(contacts_dir)

      File.write(contacts_dir / "znorth.kdl", "name \"Zed\"")
      refute_equal alone, ctag(contacts_dir)

      File.delete(contacts_dir / "znorth.kdl")
      assert_equal alone, ctag(contacts_dir)
    end
  end

  def test_the_sync_token_moves_with_the_ctag
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do |contacts_dir|
      token = ProTacts::Addressbook.load(contacts_dir).sync_token

      File.write(contacts_dir / "aiden.kdl", "name \"Aiden Smith\"")

      refute_equal token, ProTacts::Addressbook.load(contacts_dir).sync_token
    end
  end
end
