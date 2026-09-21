
# Type checking for lib/. Signatures live in the code as RBS comments
# (`#:` before a method, `# @rbs` for everything else), so the type and
# the implementation are read and changed together.
#
# sig/ holds only what inline comments cannot express: the gems we call
# into, which ship no signatures of their own, and the two Data classes
# (see sig/pro_tacts/). Both are documented where they are defined.
target :lib do
  check "lib", inline: true
  # Phlex ships no RBS of its own, and the admin views are built on it —
  # unlike Sequel, Roda, Nokogiri, and friends, which have hand written
  # stand-ins under sig/gems. Ignored rather than stubbed for now; add
  # sig/gems/phlex.rbs and drop this once the admin surface is worth
  # typing. Named file by file so that what lives beside the views
  # without being one — card_form.rb, the forms read back into cards —
  # stays checked; a new file there is checked until it is listed.
  #
  # inline: true is load-bearing: `ignore` keeps separate lists for
  # plain and inline sources, and these files were enrolled by
  # `check ... inline: true`. A bare `ignore` feeds the other list and
  # the files stay checked.
  ignore(*%w[
    avatar contact_dialog contacts_edit contacts_index contacts_show dashboard device_setup format
    group_dialog group_label groups_edit groups_index groups_show icons import_original import_review
    import_upload layout list_item phlex upcoming_birthdays
  ].map { "lib/pro_tacts/admin/#{it}.rb" }, inline: true)
  signature "sig"

  library "date", "digest", "fileutils", "json", "logger", "net-http", "open3", "pathname", "securerandom", "strscan", "time", "uri", "yaml"
end
