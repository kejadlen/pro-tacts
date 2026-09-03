
# Type checking for lib/. Signatures live in the code as RBS comments
# (`#:` before a method, `# @rbs` for everything else), so the type and
# the implementation are read and changed together.
#
# sig/ holds only what inline comments cannot express: the gems we call
# into, which ship no signatures of their own, and the two Data classes
# (see sig/pro_tacts/). Both are documented where they are defined.
target :lib do
  check "lib", inline: true
  # Phlex ships no RBS of its own, and lib/pro_tacts/admin is built on
  # it — unlike Sequel, Roda, Nokogiri, and friends, which have hand
  # written stand-ins under sig/gems. Ignored rather than stubbed for
  # now; add sig/gems/phlex.rbs and drop this once the admin surface is
  # worth typing.
  #
  # inline: true is load-bearing: `ignore` keeps separate lists for
  # plain and inline sources, and these files were enrolled by
  # `check ... inline: true`. A bare `ignore` feeds the other list and
  # the files stay checked.
  ignore "lib/pro_tacts/admin", inline: true
  signature "sig"

  library "date", "digest", "fileutils", "logger", "pathname", "strscan"
end
