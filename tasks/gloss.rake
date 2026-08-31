# Pro-tacts inherits Gloss (https://github.com/kejadlen/gloss) as its
# design system, see docs/DESIGN.md. Gloss ships as plain CSS meant to
# be copied into a consuming project rather than pulled in as a
# dependency (see its install.md), so public/vendor/gloss is a vendored
# snapshot, not a symlink or a submodule — this task is how it gets
# refreshed.

namespace :gloss do
  desc "Refresh the vendored Gloss CSS from a local checkout (GLOSS=path)"
  task :vendor do
    require "fileutils"
    require "pathname"

    checkout = Pathname.new(ENV.fetch("GLOSS") { abort "usage: rake gloss:vendor GLOSS=/path/to/gloss/checkout" })
    commit = `git -C #{checkout} rev-parse HEAD`.strip
    abort "#{checkout} is not a git checkout" unless $?.success?

    out = Pathname.new(__dir__).parent / "public" / "vendor" / "gloss"
    FileUtils.mkdir_p(out)

    header = <<~CSS
      /* Vendored from kejadlen/gloss @ #{commit}, #{Time.now.utc.strftime('%Y-%m-%d')}.
         Gloss ships this as plain CSS meant to be copied into a consuming
         project (see install.md) — there is no build step to run here.
         Refresh with `rake gloss:vendor GLOSS=/path/to/gloss/checkout`. */

    CSS

    bundles = {
      "tokens.css" => %w[assets/css/tokens.css],
      "base.css" => %w[_sass/base/reset.css _sass/base/typography.css],
      "components.css" => %w[
        _sass/components/button.css
        _sass/components/field.css
        _sass/components/badge.css
        _sass/components/card.css
        _sass/components/feedback.css
        _sass/components/tabs.css
      ],
    }

    bundles.each do |name, sources|
      body = sources.map { (checkout / it).read }.join
      (out / name).write(header + body)
      puts "wrote #{out / name}"
    end
  end
end
