require_relative "../test_helper"

require "tmpdir"

require "pro_tacts/contact"

class ContactTest < Minitest::Test
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      files.each { |name, content| File.write(File.join(dir, name), content) }
      yield ProTacts::Contact.all(dir)
    end
  end

  def test_all_parses_every_contact
    with_contacts({
      "znorth.kdl" => "name \"Zed\"",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      ids = contacts.map { it.id }

      assert_includes ids, "aiden"
      assert_includes ids, "znorth"
    end
  end

  def test_the_uid_comes_from_the_filename
    with_contacts({"kqmtnwpxlrvszoyp.kdl" => "name \"Aiden\""}) do |contacts|
      assert_includes contacts.first.vcard, "UID:kqmtnwpxlrvszoyp"
    end
  end

  def test_an_empty_directory_lists_no_contacts
    with_contacts({}) do |contacts|
      assert_empty contacts
    end
  end

  def test_a_missing_directory_raises
    error = assert_raises(ArgumentError) do
      ProTacts::Contact.all(Pathname.new(Dir.mktmpdir) / "nonexistent")
    end

    assert_match(/contacts directory not found/, error.message)
  end

  def test_non_kdl_files_raise
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notes.txt"), "hello")

      error = assert_raises(ArgumentError) { ProTacts::Contact.all(dir) }

      assert_match(/non-KDL file/, error.message)
      assert_match(/notes\.txt/, error.message)
    end
  end

  def test_dotfiles_are_ignored
    with_contacts({
      ".DS_Store" => "junk",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      assert_equal %w[aiden], contacts.map { it.id }
    end
  end

  def test_files_whose_id_cannot_be_fetched_are_skipped
    with_contacts({
      "John Smith.kdl" => "name \"John\"",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      assert_equal %w[aiden], contacts.map { it.id }
    end
  end

  def test_unparseable_files_are_skipped
    with_contacts({
      "broken.kdl" => "contact {",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      assert_equal %w[aiden], contacts.map { it.id }
    end
  end

  def test_files_whose_keys_are_not_contact_fields_are_skipped
    with_contacts({
      "person.kdl" => "person { name \"A\" }",
      "empty.kdl" => "",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      assert_equal %w[aiden], contacts.map { it.id }
    end
  end

  def test_files_whose_card_cannot_render_are_skipped
    with_contacts({
      "nameless.kdl" => "phone \"+1-555-1234\"",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |contacts|
      assert_equal %w[aiden], contacts.map { it.id }
    end
  end
end
