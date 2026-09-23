require "test_helper"

# Rack reads a rackup file with the process's default external encoding,
# which is US-ASCII under a C locale; any non-ASCII byte in one crashes
# boot (seen with rack 3.2.4). Ordinary .rb files are safe because Ruby
# parses source as UTF-8 regardless of locale.
#
# Every .ru in the root is checked rather than config.ru alone, because
# each of them is read that same way: dev.ru and demo.ru are handed to
# Rack::Builder.parse_file too, and demo.ru is what boots the preview
# app, where nothing sets a locale.
class RackupFilesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  rackup_files = Dir.glob(File.join(ROOT, "*.ru")).sort
  raise "no rackup files found in #{ROOT}" if rackup_files.empty?

  rackup_files.each do |path|
    name = File.basename(path)

    define_method(:"test_#{name.tr(".", "_")}_is_ascii_only") do
      assert File.read(path).ascii_only?,
             "#{name} must stay ASCII-only or boot crashes under a C locale"
    end
  end
end
