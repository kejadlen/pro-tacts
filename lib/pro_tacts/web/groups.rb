require "digest"

require "pro_tacts/admin/card_form"
require "pro_tacts/admin/groups_edit"
require "pro_tacts/admin/groups_index"
require "pro_tacts/admin/groups_members"
require "pro_tacts/admin/groups_show"

module ProTacts
  class Web < Roda
    # The largest group photo an upload may carry: a phone's
    # full-size JPEG fits, and the page shows the bytes as they came.
    GROUP_PHOTO_LIMIT = 10_000_000 #: Integer

    # The group screens, the contacts' own shape: the collection's
    # GET and create, then a record's GET, its editor, the POST that
    # applies it, and the members screen beside both — membership is
    # a relationship rather than a line the group holds, so it is
    # edited from the card's own screen, not the editor
    # (Admin::GroupsShow's reason). What the writes rest on is
    # docs/plans/2026-09-09-group-edits-propagate.md. A create lands
    # on the editor, a new group being nothing until something is
    # added to it.
    hash_branch("groups") do |r|
      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::GroupsIndex.call(groups: store.all_groups, login: @login)
        end

        # A create from the groups page names the group and lands on
        # its editor; one from the members screen of a group not yet
        # made (Admin::GroupsMembers, opened from a card's "new")
        # carries its first members and lands on the group itself,
        # being something already. Only ids that name a card
        # (#apply_group_edit's reason).
        r.post do
          name = typecast_params.str("name", "").strip
          members = ids_in("members") & store.contact_ids
          id = store.create_group(name: name.empty? ? nil : name, members:)
          r.redirect(r.params.key?("members") ? "/groups/#{id}" : "/groups/#{id}/edit", 303)
        rescue Sequel::UniqueConstraintViolation
          # A taken name (db/migrations/008_group_names.rb).
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::GroupsIndex.call(groups: store.all_groups, login: @login,
                                   notice: "Another group is already named #{name}.")
        end
      end

      r.on String do |id|
        r.get "edit" do
          group = store.group(id)
          group_edit_screen(group) if group
        end

        r.get "members" do
          group = store.group(id)
          members_screen(group) if group
        end

        # The group's photo (docs/plans/2026-10-12-group-photos.md):
        # served for its page's <img>, and set or removed from its
        # editor. Above the editor's POST, the members route's reason.
        r.is "photo" do
          r.get do
            photo = store.group_photo(id)

            # The page never points at a photo the group lacks, so one
            # with none is the 404 case.
            if photo
              response["Content-Type"] = photo.mime_type
              response["ETag"] = %("#{Digest::SHA256.hexdigest(photo.bytes)}")
              photo.bytes
            end
          end

          r.post do
            apply_photo(r, id)
          end
        end

        # Membership from the group's side, the members screen's save
        # (Admin::GroupsMembers). Above the editor's POST, whose bare
        # verb block would match this path too.
        r.post "members" do
          apply_members(r, id)
        end

        r.post do
          apply_group_edit(r, id)
        end

        r.get do
          group = store.group(id)

          if group
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::GroupsShow.call(
              group:,
              login: @login,
              contacts: store.listed_contacts,
              changes: store.group_changes_of(id),
            )
          end
        end
      end
    end

    private

    # The group editor's POST, #apply_edit's shape over a group: the
    # snapshot guard, then the lines the form splices
    # (Admin::CardForm.group_lines), and one store write for the lot.
    #: (untyped r, String id) -> String?
    def apply_group_edit(r, id)
      group = store.group(id)
      return if group.nil?

      if typecast_params.str!("version") != group.version
        return group_edit_screen(group, notice: "This group changed since the page loaded; nothing was saved.")
      end

      # No name at all keeps the one it has: a book's group shows its
      # name as text (Admin::GroupsEdit), where a blank one is a
      # request to go nameless. Membership is the members screen's
      # (#apply_members); the editor's form carries none.
      name = typecast_params.str("name", group.name)

      begin
        store.edit_group(id, name:, lines: Admin::CardForm.group_lines(group, card_form_params))
      rescue Sequel::UniqueConstraintViolation
        # A taken name (db/migrations/008_group_names.rb). The save is
        # one transaction, so nothing of it landed.
        return group_edit_screen(group, notice: "Another group is already named #{name}; nothing was saved.")
      end
      r.redirect "/groups/#{id}", 303
    end

    # The members screen's save, #apply_groups' shape over a group:
    # the diff of what came back against what the page loaded, so a
    # membership moved elsewhere since stays as it is, and a stale
    # page has nothing to revert and no snapshot to refuse. Only ids
    # that name a card: a membership row is a foreign key, and a
    # doctored id is ordinary bad input rather than a 500.
    #: (untyped r, String id) -> String?
    def apply_members(r, id)
      group = store.group(id)
      return if group.nil?

      known = store.contact_ids
      checked = ids_in("members") & known
      was = ids_in("was") & known
      store.edit_members(id, join: checked - was, leave: was - checked)
      r.redirect "/groups/#{id}", 303
    end

    # The editor's photo form: a removal, or an upload judged by its
    # magic bytes and its size before anything is written.
    #: (untyped r, String id) -> String?
    def apply_photo(r, id)
      group = store.group(id)
      return if group.nil?

      if r.params.key?("remove")
        store.remove_group_photo(id)
        return r.redirect("/groups/#{id}", 303)
      end

      upload = file_in("photo")
      return group_edit_screen(group, notice: "Choose a photo to upload.") if upload.nil?

      tempfile = upload.fetch(:tempfile)
      if tempfile.size > GROUP_PHOTO_LIMIT
        return group_edit_screen(group, notice: "That photo is over #{GROUP_PHOTO_LIMIT / 1_000_000} MB; nothing was saved.")
      end

      photo = Contact.photo_of(tempfile.read.b)
      return group_edit_screen(group, notice: "That file is not a JPEG, PNG, or GIF; nothing was saved.") if photo.nil?

      store.set_group_photo(id, photo)
      r.redirect "/groups/#{id}", 303
    end

    #: (Group group, ?notice: String) -> String
    def group_edit_screen(group, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::GroupsEdit.call(group:, login: @login, notice:)
    end

    #: (Group group) -> String
    def members_screen(group)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::GroupsMembers.call(group:, contacts: store.listed_contacts, login: @login)
    end
  end
end
