# A `sync:` name is unique among groups: a client's create joins its
# writer's `sync:<name>` group (Store#put), which has to be exactly one
# group (docs/plans/2026-09-12-per-user-books.md). Every other name may
# still repeat, a label being the author's to reuse, so the index is
# partial.
#
# GLOB rather than LIKE for 005's reason: its case sensitivity is its
# own rather than a per-connection pragma's. `*` is GLOB's wildcard, so
# the pattern is every name that starts `sync:`, `sync:*` itself among
# them. `glob(X, Y)` is `Y GLOB X`, pattern first, as in 005.
Sequel.migration do
  change do
    add_index :groups, :name, unique: true, name: :groups_sync_name_is_unique,
                              where: Sequel.function(:glob, "sync:*", :name)
  end
end
