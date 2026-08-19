require_relative "../test_helper"

require "tmpdir"

require "pro_tacts/contacts"

class ContactsTest < Minitest::Test
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      directory = Pathname.new(dir)
      files.each { |name, content| (directory / name).write(content) }
      yield ProTacts::Contacts.new(directory)
    end
  end

  def test_all_lists_every_contact
    with_contacts({
      "znorth.kdl" => "contact { name \"Zed\" }",
      "aiden.kdl" => "contact { name \"Aiden\" }",
    }) do |contacts|
      ids = contacts.all.map { it.id }

      assert_includes ids, "aiden"
      assert_includes ids, "znorth"
    end
  end

  def test_find_returns_the_contact_by_id
    with_contacts({"aiden.kdl" => "contact { name \"Aiden\" }"}) do |contacts|
      contact = contacts.find("aiden")

      assert_equal "aiden", contact.id
      assert_includes contact.vcard, "FN:Aiden"
    end
  end

  def test_the_uid_comes_from_the_filename
    with_contacts({"kqmtnwpxlrvszoyp.kdl" => "contact { name \"Aiden\" }"}) do |contacts|
      assert_includes contacts.find("kqmtnwpxlrvszoyp").vcard, "UID:kqmtnwpxlrvszoyp"
    end
  end

  def test_find_returns_nil_for_unknown_ids
    with_contacts({"aiden.kdl" => "contact { name \"Aiden\" }"}) do |contacts|
      assert_nil contacts.find("nope")
    end
  end

  def test_find_rejects_ids_outside_the_charset
    with_contacts({}) do |contacts|
      assert_nil contacts.find("../secrets")
      assert_nil contacts.find("a/b")
      assert_nil contacts.find("a.vcf")
    end
  end

  def test_a_missing_directory_raises
    error = assert_raises(ArgumentError) do
      ProTacts::Contacts.new(Pathname.new(Dir.mktmpdir) / "nonexistent")
    end

    assert_match(/contacts directory not found/, error.message)
  end

  def test_an_empty_directory_lists_no_contacts
    with_contacts({}) do |contacts|
      assert_empty contacts.all
    end
  end

  def test_non_kdl_files_raise
    with_contacts({
      "aiden.kdl" => "contact { name \"Aiden\" }",
      "notes.txt" => "hello",
    }) do |contacts|
      error = assert_raises(ArgumentError) { contacts.all }

      assert_match(/non-KDL file/, error.message)
      assert_match(/notes\.txt/, error.message)
    end
  end

  def test_dotfiles_are_ignored
    with_contacts({
      ".DS_Store" => "junk",
      "aiden.kdl" => "contact { name \"Aiden\" }",
    }) do |contacts|
      assert_equal %w[aiden], contacts.all.map { it.id }
    end
  end

  def test_files_whose_id_cannot_be_fetched_are_skipped
    with_contacts({
      "John Smith.kdl" => "contact { name \"John\" }",
      "aiden.kdl" => "contact { name \"Aiden\" }",
    }) do |contacts|
      assert_equal %w[aiden], contacts.all.map { it.id }
    end
  end

  def test_unparseable_files_are_skipped
    with_contacts({
      "broken.kdl" => "contact {",
      "aiden.kdl" => "contact { name \"Aiden\" }",
    }) do |contacts|
      assert_equal %w[aiden], contacts.all.map { it.id }
      assert_nil contacts.find("broken")
    end
  end

  def test_files_without_exactly_one_contact_node_are_skipped
    with_contacts({
      "empty.kdl" => "",
      "two.kdl" => "contact { name \"A\" }\ncontact { name \"B\" }",
      "other.kdl" => "person { name \"A\" }",
    }) do |contacts|
      assert_empty contacts.all
    end
  end

  def test_files_whose_card_cannot_render_are_skipped
    with_contacts({
      "nameless.kdl" => "contact { phone \"+1-555-1234\" }",
      "aiden.kdl" => "contact { name \"Aiden\" }",
    }) do |contacts|
      assert_equal %w[aiden], contacts.all.map { it.id }
      assert_nil contacts.find("nameless")
    end
  end
end
