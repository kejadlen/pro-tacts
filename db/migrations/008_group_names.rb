# A name is one group's. 007 made that true of the `sync:` names alone,
# because a client's create had to find exactly one group to join, and
# left every other name repeatable as the author's to reuse. The rest
# follow it now that a contact's groups dialog creates a group by name
# (Web#apply_groups): two groups called Booles are two tags a member
# cannot tell apart, and the save that made the second one meant the
# first.
#
# Exact bytes, the comparison 007 made. SQLite's NOCASE folds ASCII
# alone, so a folded index would refuse "booles" beside "Booles" and
# admit "ZOË" beside "Zoë" — a rule no screen could state. The dialog
# offers to create a name only when no group's lowercased label is it
# (Admin::GroupDialog), so a case variant is a hand-made POST rather
# than something the admin makes.
#
# Nameless groups are untouched, a unique index admitting any number of
# NULLs: 005 made the column nullable so that nameless is one spelling
# and a group without a name is displayed by its id.
#
# 007's index is dropped rather than left beside this one — the `sync:`
# names are a subset of every name, and the same rule held twice is the
# one that goes stale. `up` and `down` rather than `change`, because
# Sequel's reverser knows add_index and not drop_index.
Sequel.migration do
  up do
    drop_index :groups, :name, name: :groups_sync_name_is_unique
    add_index :groups, :name, unique: true, name: :groups_name_is_unique
  end

  down do
    drop_index :groups, :name, name: :groups_name_is_unique
    add_index :groups, :name, unique: true, name: :groups_sync_name_is_unique,
                              where: Sequel.function(:glob, "sync:*", :name)
  end
end
