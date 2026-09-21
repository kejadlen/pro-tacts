require_relative "../../test_helper"

require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/web"

# The import screens, exercised the way the other admin screens are:
# real requests through the Roda app against a throwaway store
# (docs/plans/2026-09-21-import-a-vcf.md).
class AdminImportPagesTest < Minitest::Test
  include Rack::Test::Methods
  include ThrowawayContacts

  JANE = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    item1.X-ABRELATEDNAMES:Sam Booles
    item1.X-ABLabel:_$!<Spouse>!$_
    X-SOCIALPROFILE;type=twitter:https://twitter.com/jb
    UID:ABC-123
    END:VCARD
  CARD

  PLAIN = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Sam;;;
    FN:Sam Booles
    UID:DEF-456
    END:VCARD
  CARD

  def app
    ProTacts::Web
  end

  def setup
    header "Remote-User", "test@example.com"
  end

  # The file as a browser sends one, written out because Rack::Test
  # uploads a path.
  def upload(bytes, name: "contacts.vcf")
    Dir.mktmpdir do |tmp|
      path = Pathname.new(tmp) / name
      path.binwrite(bytes)
      post "/import", "vcf" => Rack::Test::UploadedFile.new(path.to_s, "text/vcard", true)
    end
  end

  # The ticket to the staged file, as the review screen carries it.
  def staged = last_response.body[/name="upload" value="([a-z]+)"/, 1]

  def test_the_screen_asks_for_a_vcf
    get "/import"

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<form action="/import" method="post" enctype="multipart/form-data")
    assert_includes last_response.body, %(<input type="file" name="vcf" accept=".vcf,text/vcard">)
  end

  def test_an_upload_is_reviewed_before_anything_lands
    with_contacts({}) do |store|
      upload(JANE + PLAIN)

      assert_equal 200, last_response.status
      assert_includes last_response.body, "contacts.vcf"
      assert_includes last_response.body, "2 contacts, ready to land."
      assert_empty store.changes
    end
  end

  # The one question the screen exists to ask, with the file's own
  # values under it so it can be answered by looking.
  def test_the_review_asks_what_to_do_with_each_unknown_property
    with_contacts({}) { upload(JANE) }

    assert_includes last_response.body, "X-ABRELATEDNAMES (1 line)"
    assert_includes last_response.body, "X-SOCIALPROFILE (1 line)"
    assert_includes last_response.body, "item1.X-ABRELATEDNAMES:Sam Booles"
    %w[drop note].each do |choice|
      assert_includes last_response.body,
                      %(<input type="radio" name="decide[X-SOCIALPROFILE]" value="#{choice}")
    end
    # Nothing here will show it, so leaving it behind is what an
    # unread form sends, and there is no third choice that keeps it.
    assert_includes last_response.body,
                    %(name="decide[X-SOCIALPROFILE]" value="drop" checked>)
    refute_includes last_response.body, %(value="keep")
  end

  def test_a_file_this_book_reads_whole_has_nothing_to_decide
    with_contacts({}) { upload(PLAIN) }

    assert_includes last_response.body, "Nothing to decide."
    refute_includes last_response.body, "stays behind"
    refute_includes last_response.body, "decide["
  end

  def test_confirming_lands_the_cards_with_the_decisions_applied
    with_contacts({}) do |store|
      upload(JANE)

      post "/import/land",
           "upload" => staged,
           "group" => "import-20260921T031655Z",
           "decide" => {"X-ABRELATEDNAMES" => "note"}

      assert_equal 200, last_response.status
      assert_includes last_response.body, "landed (1)"

      contact = store.contacts.fetch(0)

      assert_equal "Jane Booles", contact.name
      assert_includes last_response.body, %(href="/contacts/#{contact.id}")
      refute_includes contact.vcard.to_s, "X-SOCIALPROFILE"
      assert_includes contact.vcard.to_s, "NOTE:Spouse: Sam Booles"
      assert_includes store.all_groups.map(&:name), "import-20260921T031655Z"
    end
  end

  # Leaving it behind is what nobody has to ask for, so a form
  # submitted without touching a radio brings in only what shows.
  def test_confirming_with_no_answers_leaves_the_unknown_behind
    with_contacts({}) do |store|
      upload(JANE)

      post "/import/land", "upload" => staged, "group" => ""

      card = store.contacts.fetch(0).vcard.to_s

      refute_includes card, "X-SOCIALPROFILE"
      refute_includes card, "X-ABRELATEDNAMES"
      assert_includes card, "FN:Jane Booles"
      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
    end
  end

  # Swept out from under a review screen left open, or a confirm
  # submitted twice: the file is gone and only the person has another.
  def test_a_confirm_with_no_staged_file_lands_nothing
    with_contacts({}) do |store|
      upload(JANE)
      id = staged

      post "/import/land", "upload" => id, "group" => ""
      post "/import/land", "upload" => id, "group" => ""

      assert_includes last_response.body, "That upload is no longer here."
      assert_equal 1, store.contacts.length
    end
  end

  # An id off a form is a filename if nothing checks it.
  def test_an_upload_id_this_server_never_minted_reads_nothing
    with_contacts({}) do |store|
      post "/import/land", "upload" => "../../contacts.db", "group" => ""

      assert_includes last_response.body, "That upload is no longer here."
      assert_empty store.changes
    end
  end

  def test_an_upload_with_no_file_says_what_to_choose
    with_contacts({}) do |store|
      post "/import"

      assert_includes last_response.body, "Choose a .vcf file to import."
      assert_empty store.changes
    end
  end

  def test_a_file_that_is_not_a_set_of_vcards_lands_nothing
    with_contacts({}) do |store|
      upload("hello\r\n")

      assert_includes last_response.body, "a line outside a card"
      assert_empty store.changes
    end
  end

  # Web#write_card's rule over the one other body this app reads:
  # bytes that are not the text they claim to be are refused where
  # they are read, rather than at the insert that would 500 on them.
  def test_a_file_that_is_not_utf_8_lands_nothing
    with_contacts({}) do |store|
      upload(JANE.b.sub("Jane".b, "Jan\xFF".b))

      assert_includes last_response.body, "contacts.vcf is not UTF-8 text."
      assert_empty store.changes
    end
  end
end
