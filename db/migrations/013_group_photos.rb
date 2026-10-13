# A group's photo: a picture the group's own page shows and nothing
# else does (docs/plans/2026-10-12-group-photos.md). Not a line in
# group_properties, because every line there is composed into a
# member's card and this must never reach a client — so not under that
# table's CHECK either, which is what keeps a PHOTO line out of it.
#
# Its own table rather than a column on groups, so the reads that hand
# out a group never carry megabytes they will not show, and a group's
# delete cascades the picture away with it. The bytes only: the mime
# type is read off them (Contact.photo_of), which the upload already
# did to accept them.
#
# `text: true` on the id because this is a STRICT table, which refuses
# Sequel's plain String; `File` is a BLOB, which STRICT admits.
Sequel.migration do
  change do
    create_table(:group_photos, strict: true) do
      foreign_key :group_id, :groups, type: String, text: true, primary_key: true, null: false,
                                      on_delete: :cascade
      File :bytes, null: false
    end
  end
end
