# A readable copy of what the store cannot rebuild: each stored card as
# its bytes, the birthdays, and the groups, split the way the store
# splits them (docs/plans/2026-09-12-database-dump.md). cards/ and
# groups/ are made to hold exactly what the store holds, so a dump kept
# in version control shows deletions too; anything else in the
# directory is left alone.

require "pathname"
require "pro_tacts"

dump = Pathname.new(ENV.fetch("DUMP") { (ProTacts.config.data_dir / "dump").to_s })
cards = dump / "cards"
groups = dump / "groups"

directory cards.to_s
directory groups.to_s

namespace :db do
  desc "Dump the cards, birthdays, and groups into #{dump} (DUMP=path to move it)"
  task dump: [cards.to_s, groups.to_s] do
    require "yaml"
    require "pro_tacts/store"

    database = ProTacts.config.database_path
    ProTacts::Store.connect(database) do |store|
      snapshot = store.snapshot

      dump_directory(cards, snapshot.cards.to_h { |id, card| ["#{id}.vcf", card] })

      birthdays = snapshot.birthdays.sort_by { |id, _| id }.to_h { |id, birthday|
        [id, {"year" => birthday.year, "month" => birthday.month, "day" => birthday.day}.compact]
      }
      dump_file(dump / "birthdays.yml", YAML.dump(birthdays))

      dump_directory(groups, snapshot.groups.to_h { |group|
        ["#{group.id}.yml", YAML.dump({"name" => group.name, "lines" => group.lines, "members" => group.members})]
      })
    end
    puts "dumped #{database} into #{dump}"
  end

  # A directory holding exactly these files, so what left the store
  # leaves the dump.
  def dump_directory(directory, files)
    directory.children.each { it.delete unless files.key?(it.basename.to_s) }
    files.each { |name, content| dump_file(directory / name, content) }
  end

  # Unchanged files are not rewritten, so a dump over a dump touches
  # only what moved. Compared as bytes: a card is UTF-8 and a file read
  # back is binary.
  def dump_file(path, content)
    path.binwrite(content) unless path.exist? && path.binread == content.b
  end
end
