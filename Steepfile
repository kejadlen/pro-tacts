
# Type checking for lib/. Signatures live in the code as RBS comments
# (`#:` before a method, `# @rbs` for everything else), so the type and
# the implementation are read and changed together.
#
# sig/ holds only what inline comments cannot express: the gems we call
# into, which ship no signatures of their own, and the two Data classes
# (see sig/pro_tacts/). Both are documented where they are defined.
target :lib do
  check "lib", inline: true
  signature "sig"

  library "digest", "fileutils", "logger", "pathname", "strscan"
end
