require_relative "../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/contact"

class ContactTest < Minitest::Test
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      directory = Pathname.new(dir)
      files.each { |name, content| File.write(directory / name, content) }
      yield directory
    end
  end

  def test_all_parses_every_contact
    with_contacts({
      "znorth.kdl" => "name \"Zed\"",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |directory|
      ids = ProTacts::Contact.all(directory).map { it.id }

      assert_includes ids, "aiden"
      assert_includes ids, "znorth"
    end
  end

  def test_the_uid_comes_from_the_filename
    with_contacts({"kqmtnwpxlrvszoyp.kdl" => "name \"Aiden\""}) do |directory|
      assert_includes ProTacts::Contact.all(directory).first.vcard, "UID:kqmtnwpxlrvszoyp"
    end
  end

  def test_an_empty_directory_lists_no_contacts
    with_contacts({}) do |directory|
      assert_empty ProTacts::Contact.all(directory)
    end
  end

  def test_dotfiles_are_ignored
    with_contacts({
      ".DS_Store" => "junk",
      "aiden.kdl" => "name \"Aiden\"",
    }) do |directory|
      assert_equal %w[aiden], ProTacts::Contact.all(directory).map { it.id }
    end
  end

  def test_a_missing_directory_raises
    error = assert_raises(Errno::ENOENT) do
      ProTacts::Contact.all(Pathname.new(Dir.mktmpdir) / "nonexistent")
    end

    assert_match(/nonexistent/, error.message)
  end

  def test_non_kdl_files_raise
    with_contacts({"notes.txt" => "hello"}) do |directory|
      error = assert_raises(ArgumentError) { ProTacts::Contact.all(directory) }

      assert_equal "invalid contact id: notes.txt", error.message
    end
  end

  def test_filenames_that_are_not_ids_raise
    with_contacts({"John Smith.kdl" => "name \"John\""}) do |directory|
      error = assert_raises(ArgumentError) { ProTacts::Contact.all(directory) }

      assert_equal "invalid contact id: John Smith", error.message
    end
  end

  def test_unparseable_files_raise
    with_contacts({"broken.kdl" => "contact {"}) do |directory|
      assert_raises(KDL::ParseError) { ProTacts::Contact.all(directory) }
    end
  end

  def test_files_whose_keys_are_not_contact_fields_raise
    with_contacts({"person.kdl" => "person { name \"A\" }"}) do |directory|
      error = assert_raises(ArgumentError) { ProTacts::Contact.all(directory) }

      assert_equal "unknown key in contact: person", error.message
    end
  end

  def test_empty_files_raise
    with_contacts({"empty.kdl" => ""}) do |directory|
      error = assert_raises(ArgumentError) { ProTacts::Contact.all(directory) }

      assert_equal "contact requires a name", error.message
    end
  end

  def test_files_whose_card_cannot_render_raise
    with_contacts({"nameless.kdl" => "phone \"+1-555-1234\""}) do |directory|
      error = assert_raises(ArgumentError) { ProTacts::Contact.all(directory) }

      assert_equal "contact requires a name", error.message
    end
  end
end
