# A readable copy of what the store cannot rebuild: each stored card as
# its bytes, the birthdays, and the groups, split the way the store
# splits them (docs/plans/2026-09-12-database-dump.md). cards/ and
# groups/ are made to hold exactly what the store holds, so a dump kept
# in version control shows deletions too; anything else in the
# directory is left alone.
#
# The dump then commits what it wrote, into a repository of its own
# beside the code's — `data/` is ignored here — so a snapshot can be
# reverted to rather than overwritten by the next one
# (docs/plans/2026-09-20-the-dump-commits.md). This is the one place
# the tooling runs git; the app still runs none.

require "open3"
require "pathname"
require "pro_tacts"

dump = Pathname.new(ENV.fetch("DUMP") { (ProTacts.config.data_dir / "dump").to_s })
cards = dump / "cards"
groups = dump / "groups"

directory cards.to_s
directory groups.to_s

namespace :db do
  desc "Dump the cards, birthdays, and groups into #{dump} and commit them there (DUMP=path to move it)"
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
    commit_dump(dump)
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

  # The repository is the dump's own, made on the first dump. The
  # identity is passed per invocation rather than read from the
  # machine's git configuration, so a host that dumps needs none set up
  # (docs/plans/2026-09-20-the-dump-commits.md).
  def commit_dump(dump)
    sh "git", "-C", dump.to_s, "init", "-b", "main" unless (dump / ".git").exist?
    sh "git", "-C", dump.to_s, "add", "--all"

    # Porcelain is the whole answer: empty means nothing to commit, so a
    # dump that moved nothing adds no commit and the history is the
    # writes rather than the runs. A failure here raises rather than
    # leaving a caller believing the snapshot was recorded.
    staged, error, = Open3.capture3("git", "-C", dump.to_s, "status", "--porcelain")
    raise error unless error.empty?
    return if staged.empty?

    # The time is all a snapshot has to say for itself; what moved is
    # the store's change log, which the dump deliberately leaves out.
    sh "git", "-C", dump.to_s,
      "-c", "user.name=pro-tacts", "-c", "user.email=dump@localhost",
      "-c", "commit.gpgsign=false",
      "commit", "--message", "dump #{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
  end
end
