require_relative "../../test_helper"

require "json"
require "pathname"
require "tmpdir"

require "pro_tacts/import/macos"
require "pro_tacts/import/plan"

class ImportMacosTest < Minitest::Test
  Macos = ProTacts::Import::Macos

  Card = ProTacts::Import::Card

  CREATED_AT = Time.utc(2026, 9, 16, 18, 4, 12)
  NAME = ["N:Lovelace;Ada;;;", "FN:Ada Lovelace"].freeze
  GROUPS = ["sync:*", "import-20260916T180412Z"].freeze

  def record(identifier, name: NAME, lines: [], note: nil, image: nil)
    {
      "identifier" => identifier,
      "vcard" => ["BEGIN:VCARD", "VERSION:3.0", *name, *lines, "END:VCARD", ""].join("\r\n"),
      "contact" => {"identifier" => identifier, "imageData" => image},
      "note" => note
    }
  end

  def in_tmpdir
    Dir.mktmpdir { yield Pathname.new(it) / "plan" }
  end

  def test_a_named_card_is_planned_under_a_minted_id
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson")], created_at: CREATED_AT)

      assert_equal 1, plan.contacts.size
      contact = plan.contacts.first
      assert_match(/\A[k-z]{12}\z/, contact.id)
      assert_equal "A:ABPerson", contact.source_id
      assert_equal Card.new(first: "Ada", last: "Lovelace", phones: [], groups: GROUPS), plan.card(contact.id)
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
        record("A:ABPerson", lines: ["ORG:Analytical Engines;", "EMAIL:ada@example.com"], note: "Analyst."),
        record("B:ABPerson", lines: ["EMAIL:mary@example.com"], image: "/9j/")
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          EMAIL: 2
            A:ABPerson: "EMAIL:ada@example.com"
            B:ABPerson: "EMAIL:mary@example.com"
          ORG: 1
            A:ABPerson: "ORG:Analytical Engines;"
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

  def test_a_cell_number_is_a_phone
    in_tmpdir do |dir|
      lines = ["TEL;type=CELL;type=VOICE;type=pref:+12532189075", "TEL;type=CELL;type=VOICE;type=pref:+12532189076"]
      plan = Macos.plan(dir, [record("A:ABPerson", lines:)], created_at: CREATED_AT)

      assert_equal ["+12532189075", "+12532189076"], plan.card(plan.contacts.first.id).phones
    end
  end

  def test_a_name_is_read_unescaped
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson", name: ["N:O\\,Brien;Ada;;;", "FN:Ada O\\,Brien"])], created_at: CREATED_AT)

      assert_equal "O,Brien", plan.card(plan.contacts.first.id).last
    end
  end

  def test_a_name_beyond_first_and_last_is_refused
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", name: ["N:Lovelace;Ada;Augusta;;", "FN:Ada Lovelace"]),
        record("B:ABPerson", name: ["N:Lovelace;Ada;;;", "FN:Countess Ada Lovelace"]),
        record("C:ABPerson", name: ["FN:Ada Lovelace"]),
        record("D:ABPerson", name: ["N:;;;;", "FN:"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          FN other than first and last: 2
            B:ABPerson: "FN:Countess Ada Lovelace"
            C:ABPerson: "FN:Ada Lovelace"
          N beyond first and last: 1
            A:ABPerson: "N:Lovelace;Ada;Augusta;;"
          N lines: 0: 1
            C:ABPerson: ""
          no name: 1
            D:ABPerson: "N:;;;;"
      MESSAGE
    end
  end

  def test_an_apple_prodid_is_dropped
    in_tmpdir do |dir|
      plan = Macos.plan(dir, [record("A:ABPerson", lines: ["PRODID:-//Apple Inc.//macOS 26.0//EN"])], created_at: CREATED_AT)

      assert_equal Card.new(first: "Ada", last: "Lovelace", phones: [], groups: GROUPS), plan.card(plan.contacts.first.id)
    end
  end

  def test_any_other_prodid_is_refused
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["PRODID:-//Monica//EN"]),
        record("B:ABPerson", lines: ["PRODID;VALUE=text:-//Apple Inc.//macOS 26.0//EN"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          PRODID value: 1
            A:ABPerson: "PRODID:-//Monica//EN"
          PRODID;VALUE=text: 1
            B:ABPerson: "PRODID;VALUE=text:-//Apple Inc.//macOS 26.0//EN"
      MESSAGE
    end
  end

  def test_a_line_in_any_other_form_is_refused_under_that_form
    in_tmpdir do |dir|
      records = [
        record("A:ABPerson", lines: ["TEL;type=HOME;type=VOICE:+12532189075"]),
        record("B:ABPerson", lines: ["TEL;type=CELL;type=VOICE:+12532189075"]),
        record("C:ABPerson", lines: ["item1.TEL;type=CELL;type=VOICE;type=pref:+12532189075"]),
        record("D:ABPerson", lines: ["TEL;type=CELL;type=VOICE;type=pref:(253) 218-9075"]),
        record("E:ABPerson", name: ["N:Lovelace;Ada;;;", "FN;CHARSET=utf-8:Ada Lovelace"])
      ]

      error = assert_raises(Macos::Unknown) { Macos.plan(dir, records, created_at: CREATED_AT) }

      assert_equal <<~MESSAGE.chomp, error.message
        no branch handles these fields, so no plan was written:
          FN lines: 0: 1
            E:ABPerson: ""
          FN;CHARSET=utf-8: 1
            E:ABPerson: "FN;CHARSET=utf-8:Ada Lovelace"
          TEL value: 1
            D:ABPerson: "TEL;type=CELL;type=VOICE;type=pref:(253) 218-9075"
          TEL;type=CELL;type=VOICE: 1
            B:ABPerson: "TEL;type=CELL;type=VOICE:+12532189075"
          TEL;type=HOME;type=VOICE: 1
            A:ABPerson: "TEL;type=HOME;type=VOICE:+12532189075"
          item1.TEL;type=CELL;type=VOICE;type=pref: 1
            C:ABPerson: "item1.TEL;type=CELL;type=VOICE;type=pref:+12532189075"
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
