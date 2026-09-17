require_relative "../../test_helper"

require "json"
require "pathname"
require "tmpdir"

require "pro_tacts/import/macos"
require "pro_tacts/import/plan"

class ImportMacosTest < Minitest::Test
  Macos = ProTacts::Import::Macos

  CREATED_AT = Time.utc(2026, 9, 16, 18, 4, 12)

  def record(identifier, lines: [], note: nil, image: nil)
    {
      "identifier" => identifier,
      "vcard" => ["BEGIN:VCARD", "VERSION:3.0", *lines, "END:VCARD", ""].join("\r\n"),
      "contact" => {"identifier" => identifier, "imageData" => image},
      "note" => note
    }
  end

  def in_tmpdir
    Dir.mktmpdir { yield Pathname.new(it) / "plan" }
  end

  def test_an_empty_card_is_planned_under_a_minted_uid
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson")], created_at: CREATED_AT)

      assert_equal 1, plan.contacts.size
      contact = plan.contacts.first
      assert_match(/\A[k-z]{12}\z/, contact.id)
      assert_equal "A:ABPerson", contact.source_id
      assert_equal "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:#{contact.id}\r\nEND:VCARD\r\n", plan.card(contact.id)
    end
  end

  def test_the_backup_holds_the_vcard_and_the_keys
    in_tmpdir do |dir|
      source = record("A:ABPerson")
      plan = Macos.plan(dir, [source], created_at: CREATED_AT)

      backup = dir / "backups" / plan.contacts.first.id
      assert_equal source.fetch("vcard"), (backup / "original.vcf").read
      assert_equal source.fetch("contact"), JSON.parse((backup / "contact.json").read)
      refute (backup / "note.txt").exist?
    end
  end

  def test_every_unknown_field_is_named_and_no_plan_is_written
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["N:Lovelace;Ada;;;", "FN:Ada Lovelace"], note: "Analyst."),
        record("B:ABPerson", lines: ["FN:Mary Boole"], image: "/9j/")
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          FN: 2
            A:ABPerson: "FN:Ada Lovelace"
            B:ABPerson: "FN:Mary Boole"
          N: 1
            A:ABPerson: "N:Lovelace;Ada;;;"
          imageData: 1
            B:ABPerson: "/9j/"
          note: 1
            A:ABPerson: "Analyst."
      MESSAGE
      refute dir.exist?
    end
  end

  def test_examples_are_distinct_unfolded_and_cut_short
    in_tmpdir do |dir|
      records = %w[A B C D].map { record("#{it}:ABPerson", lines: ["PHOTO;ENCODING=b:#{"A" * 60}\r\n #{"A" * 60}"]) }
      records << record("E:ABPerson", lines: ["NOTE:one\\ntwo"], note: "one\ntwo")
      records << record("F:ABPerson", lines: ["NOTE:one\\ntwo"])

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          NOTE: 2
            E:ABPerson: "NOTE:one\\\\ntwo"
          PHOTO: 4
            A:ABPerson: "PHOTO;ENCODING=b:#{"A" * 83}… (137 characters)"
          note: 1
            E:ABPerson: "one\\ntwo"
      MESSAGE
    end
  end

  def test_a_card_that_is_not_version_3_is_refused
    in_tmpdir do |dir|
      source = record("A:ABPerson")
      source["vcard"] = source.fetch("vcard").sub("VERSION:3.0", "VERSION:4.0")

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, [source], created_at: CREATED_AT) }

      assert_includes error.message, "VERSION:4.0: 1"
    end
  end
end
