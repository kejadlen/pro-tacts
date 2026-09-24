require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/import_groups"
require "pro_tacts/admin/import_original"
require "pro_tacts/admin/import_saved"
require "pro_tacts/admin/import_sidebar"
require "pro_tacts/admin/import_target"
require "pro_tacts/admin/import_upload"
require "pro_tacts/birthday"
require "pro_tacts/import/match"
require "pro_tacts/import/merge"
require "pro_tacts/import/write"
require "pro_tacts/import/staged"
require "pro_tacts/import/vcf"

module ProTacts
  class Web < Roda
    # The import screens: a .vcf, read, looked over contact by
    # contact, and written into the store
    # (docs/plans/2026-09-21-import-a-vcf.md).
    # They replace the rake tasks that read Contacts.app on a Mac,
    # built a plan directory, and carried it to a host over HTTP — a
    # .vcf is what every address book on earth already exports, and
    # the machine holding it is whichever one the browser is on.
    #
    # Two screens, because an import is a walk rather than a
    # submission: choose the file, and open any of its contacts
    # beside the card it arrived as. The Save on that screen is the
    # import of that one contact — not a note kept until a confirm
    # at the end — and then the walk is on the next row nobody has
    # read, so what is left when the walk stops is only the part
    # nobody looked at. The list is a sidebar rather than a screen
    # of its own (Admin::ImportSidebar): it stands beside every
    # card, so opening a row never costs your place in it, and what
    # the file is losing is said on the rows (the dropped count) and
    # on the cards (the struck lines) rather than on a screen about
    # the file — a stop between saves that repeated what the list
    # beside every card already said.
    #
    # Under the same identity gate as every other route (web.rb),
    # which is also where the arrivals' books come from: a card this
    # creates joins everyone's book the way a client's create does, so
    # the person importing does not have to be the person syncing.
    hash_branch("import") do |r|
      r.is do
        r.get do
          import_screen
        end

        r.post do
          stage_upload(r)
        end
      end

      r.on String do |upload|
        # The contact's place in the file is its name here, until its
        # own Save mints one. The file's own order is the one thing
        # about a card that cannot change under the walk: the editor's
        # save rewrites a card in place and never adds or removes one.
        r.on Integer do |index|
          r.is do
            # `into` is the contact the row's editor is folding its
            # card into, chosen at the top of that editor
            # (Admin::ImportTarget): an empty `into` is the new contact
            # chosen against the default, and none at all the default
            # itself, the contact the card looks like most.
            r.get do
              card_screen(upload, index, into: r.params.key?("into") ? r.params["into"].to_s : nil)
            end

            r.post do
              save_card(r, upload, index)
            end
          end

          # The stored contact's editor, reached from its row's read
          # screen: the same amend the contact's own page's edit link
          # writes, kept inside the walk (Web#edit_card_screen). A
          # row still to do is already its editor, so its edit is the
          # row screen itself.
          r.get "edit" do
            edit_card_screen(r, upload, index)
          end
        end
      end
    end

    private

    # The upload's own POST: the file read and judged whole before
    # anything is staged, the old `execute`'s rule that a source which
    # will not read brings in nothing. What it stages is both readings —
    # the file as it arrived, and the cards pared to what this book
    # shows — and then it is the walk's first card.
    #: (untyped r) -> untyped
    def stage_upload(r)
      upload = file_in(r.params["vcf"])
      return import_screen(notice: "Choose a .vcf file to import.") if upload.nil?

      name = File.basename(upload[:filename].to_s)
      # Relabelled and judged in the same breath, Web#write_card's rule
      # for the one other body this app reads: a multipart part arrives
      # as binary, and a force_encoding nobody validates is a lie every
      # later reader inherits.
      bytes = upload.fetch(:tempfile).read.force_encoding(Encoding::UTF_8)
      return import_screen(notice: "#{name} is not UTF-8 text.") unless bytes.valid_encoding?

      begin
        cards = Import::Vcf.cards(bytes)
      rescue Import::Vcf::Invalid => error
        return import_screen(notice: error.message)
      end

      id = Import::Staged.open(
        original: bytes,
        revised: joined(cards.map { Import::Vcf.read(it).card }),
        # Named here and not at the end, there being no end to name
        # it at: every Save files its contact under it. Not the
        # importer's to rename either — a name typed before anything
        # has been looked at is a name for nothing, and one typed
        # after would split an import across two groups. What is
        # editable is the membership, beside each contact's own card
        # and a contact at a time (#import_picker).
        group: Import::Write.default_group,
      )
      # Straight to the first contact rather than to a screen about
      # the file: the walk is the point, and a list that has just been
      # built from a file nobody has looked at yet is a stop on the
      # way to the same place — the list stands beside every card
      # anyway (Admin::ImportSidebar).
      #
      # A 303, the other writes' answer, because what follows is a
      # walk: every screen of it is a GET a back button can revisit.
      r.redirect "/import/#{id}/0", 303
    end

    # The walk's list of contacts, as every screen of it shows them:
    # the contact each card will be written as, how many of its
    # original's lines are not coming with it, and which rows are in
    # the book already. `current` is the row whose screen is open.
    #: (String upload, Array[VCard] originals, Array[VCard] revised, Hash[String, String] saved, current: Integer) -> Admin::ImportSidebar
    def walk_sidebar(upload, originals, revised, saved, current:)
      rows = revised.each_with_index.map { |card, index|
        # A literal of several elements is an Array until something
        # says otherwise, and an inline annotation needs its own line.
        dropped = Import::Vcf.read(originals.fetch(index)).dropped
        [import_contact(card, index), Import::Vcf.losses(dropped).length] #: [Contact, Integer]
      }
      Admin::ImportSidebar.new(upload:, rows:, saved:, current:)
    end

    # A row opened: the card it arrived as beside the card that is
    # coming in — or the contact itself, for a card this walk has
    # One contact, the card it arrived as beside the card that is
    # coming in. The right-hand half is the contact editor itself, not a
    # copy of it: a field the two disagreed about would be a field an
    # import writes and an edit cannot undo.
    #
    # A row this walk has saved opens over the stored contact rather
    # than the staged card — a look back, not a navigation away from
    # the list to the contact's own page — and reads: the write
    # happened at the row's Save, so there is no form to submit and
    # what it wrote is changed where every other contact is
    # (Admin::ImportSaved). A stored id naming no contact (deleted
    # from the book since its Save) is the unsaved screen, there
    # being nothing stored to open; its Save is the import POST's own
    # double-write guard to catch.
    #
    # A row not saved yet can be written two ways, and `into` says
    # which: nil for the screen no choice was made about, which folds
    # into the contact the card looks like most (Import::Match), blank
    # for a new contact, or the id of one the book already has, whose
    # editor this becomes with the card folded in
    # (Import::Merge) — the lines that fold leaves behind struck on the
    # card as exported beside it, as the ones the import itself drops
    # are. An id naming nobody (a contact deleted since the toggle was
    # drawn) is the new contact, there being nothing to fold into.
    #
    # `joined` and `named` are the groups a refused save had ticked,
    # and none on the way in: nothing is staged between screens, the
    # Save that would have written an answer being the Save that
    # writes the contact, so a card opened afresh is asked the
    # question with the defaults ticked (#import_picker) rather than
    # with an earlier answer read back.
    #: (String upload, Integer index, ?into: String?, ?notice: String?, ?joined: Array[String]?, ?named: Array[String]?) -> String?
    def card_screen(upload, index, into: "", notice: nil, joined: nil, named: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, revised = staged
      original = originals[index]
      card = revised[index]
      # An index past the end of the file is the empty-body 404 the
      # not_found handler fills in, the same as a contact id nobody
      # has.
      return nil if original.nil? || card.nil?

      group, saved = Import::Staged.saved(upload)
      stored = saved[index.to_s]
      contact = stored ? store.contact(stored) : nil
      dropped = Import::Vcf.read(original).dropped
      sidebar = walk_sidebar(upload, originals, revised, saved, current: index)

      response["Content-Type"] = "text/html; charset=utf-8"
      return Admin::ImportSaved.call(
        contact:,
        login: @login,
        groups: store.groups_of(contact.id),
        all_groups: store.group_choices,
        aside: Admin::ImportOriginal.new(card: original, dropped:),
        sidebar:,
        edit: "/import/#{upload}/#{index}/edit",
        land: "/import/#{upload}/#{index}",
        notice:,
      ) if contact

      arriving = import_contact(card, index)
      matches = Import::Match.candidates(arriving, store.contacts)
      target = into.nil? || into.empty? ? nil : store.contact(into)
      # The row opened with no choice made is the first choice
      # offered, the best match
      # (docs/plans/2026-09-23-update-is-the-default.md).
      target ||= matches.first if into.nil?
      merge = target && Import::Merge.new(target, card)
      Admin::ContactsEdit.call(
        contact: merge ? merge.contact : arriving,
        login: @login,
        notice:,
        action: "/import/#{upload}/#{index}",
        # The submit says what it does — the import of this one
        # contact, or the update of the one it is folded into —
        # because this is the one editor in the app whose Save can
        # create the record rather than amend it. The row beside it
        # wears its check only once this has been pressed
        # (Admin::ImportSidebar).
        save: merge ? "Update" : "Import",
        aside: Admin::ImportOriginal.new(card: original, dropped: merge ? dropped + merge.left : dropped),
        fields: import_picker(group, joined, named, member: target),
        lead: import_target(upload, index, matches, target),
        sidebar:,
      )
    end

    # The toggle at the top of an unsaved row's editor, or none when
    # nothing in the book looks like the card: the contacts it might
    # be (Import::Match), read off the card as it arrived rather than
    # as the fold would make it. The one being updated is always among
    # them — a toggle has to show the side it is on, and a contact
    # edited since it was offered can have stopped looking like the
    # card.
    #: (String upload, Integer index, Array[Contact] matches, Contact? target) -> Admin::ImportTarget?
    def import_target(upload, index, matches, target)
      matches = [target, *matches] if target && matches.none? { it.id == target.id }
      return nil if matches.empty?

      Admin::ImportTarget.new(row: "/import/#{upload}/#{index}", matches:, into: target)
    end

    # The editor over a stored row's contact, reached from that row's
    # read screen: #apply_edit's form — the contact's own card, its
    # etag, no group boxes — posting to the row itself, where the
    # amend branch of #save_card answers (its `refuse` and `land` are
    # this screen and the row's). `contact` is the fresh one a
    # refusal is re-rendering, and none passed means the stored one;
    # a row with nothing stored is already its editor, so its edit
    # goes back to the row screen.
    #: (untyped r, String upload, Integer index, ?contact: Contact?, ?notice: String?) -> untyped
    def edit_card_screen(r, upload, index, contact: nil, notice: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, revised = staged
      original = originals[index]
      return nil if original.nil?

      _group, saved = Import::Staged.saved(upload)
      stored = saved[index.to_s]
      contact ||= stored ? store.contact(stored) : nil
      return r.redirect "/import/#{upload}/#{index}", 303 if contact.nil?

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(
        contact:,
        login: @login,
        notice:,
        action: "/import/#{upload}/#{index}",
        save: "Save",
        aside: Admin::ImportOriginal.new(card: original, dropped: Import::Vcf.read(original).dropped),
        sidebar: walk_sidebar(upload, originals, revised, saved, current: index),
      )
    end

    # The groups beside one card: this book's own list, with the two
    # an arrival comes in under already ticked. Both are boxes like
    # any other — unticking everyone's book is how a card comes in
    # without going out to anybody's phone, and unticking the
    # import's own group is how an arrival that does not belong with
    # the lot says so.
    #
    # The group for the import is a name rather than an id until
    # something makes it, which is the first Save to go in under it
    # (Import::Write#group_id), so it rides as one of the staged
    # names on that first screen and as an ordinary box after.
    # Everyone's book is missing from the list on one screen in the
    # life of a server — the first card of the first import into an
    # empty book, which is the write that creates it — and a row for
    # a group that does not exist would be a worse answer than none.
    #
    # A card being folded into a contact the book already has
    # (`member`) comes in under that contact's groups instead of
    # everyone's book: they are ticked, and sent back as `was[]` so the
    # save moves only what was toggled. The group for the import is
    # ticked beside them all the same, so the group the walk ends on
    # lists every contact it touched.
    #: (String group, Array[String]? joined, Array[String]? named, ?member: Contact?) -> Admin::ImportGroups
    def import_picker(group, joined, named, member: nil)
      choices = store.group_choices
      lot = group.empty? ? nil : choices.find { it.name == group }
      everyone = choices.find { it.name == Group::EVERYONE }
      none = [] #: Array[String]
      was = member ? store.groups_of(member.id).map(&:id) : none
      ticked = member ? was : [everyone&.id].compact
      Admin::ImportGroups.new(
        groups: choices,
        joined: joined || [*ticked, lot&.id].compact.uniq,
        named: named || [(group unless lot || group.empty?)].compact,
        was:,
      )
    end

    # The editor's save, which is this contact's import: #apply_edit's
    # shape over a card that is not a contact yet, down to the
    # refusals, because it is the same form — and then the write, the
    # card and its groups going in together.
    #: (untyped r, String upload, Integer index) -> untyped
    def save_card(r, upload, index)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      _originals, revised = staged
      card = revised[index]
      return nil if card.nil?

      _group, saved = Import::Staged.saved(upload)
      # A Save pressed twice, or a back button onto the editor of a
      # contact that is already in the book: a second write here
      # would be a second contact rather than an edit of the first,
      # there being no id in the file to recognise it by, so the POST
      # over a stored row is that row's own editor's Save instead —
      # the same amend the contact's own page writes (#apply_edit),
      # landing back on the row's read screen.
      stored = saved[index.to_s]
      contact = stored ? store.contact(stored) : nil
      if contact
        return apply_edit(r, contact.id,
                          refuse: ->(fresh, notice:) { edit_card_screen(r, upload, index, contact: fresh, notice:) },
                          land: "/import/#{upload}/#{index}")
      end

      # A card being folded into a contact the book already has
      # (#card_screen's `into`): that contact's editor, the fold
      # derived again here rather than trusted from the page, so the
      # etag below refuses a save over a contact that changed since.
      # One gone since is refused outright — writing the card as a new
      # contact instead would be a different Save than the one pressed.
      into = r.params["into"].to_s
      target = into.empty? ? nil : store.contact(into)
      if !into.empty? && target.nil?
        return card_screen(upload, index, notice: "The contact this card was updating is gone; nothing was saved.")
      end

      merge = target && Import::Merge.new(target, card)
      contact = merge ? merge.contact : import_contact(card, index)
      # Which toggle the refusals below re-render under.
      into = target ? target.id : ""

      # The groups ride in the same form and are written by the same
      # Save (Admin::ImportGroups): a card the walk has looked at is
      # decided about in both ways at once. Only ids naming a group,
      # #apply_groups' own rule, and the boxes are the whole answer —
      # none ticked is none joined, the group for the import included,
      # which is a box like any other here (#import_picker). A name
      # typed into the filter is committed by its tick into the
      # standing names (Admin::GroupFilter), so it survives the
      # filter being cleared, and is made by the write below
      # (Import::Write#group_id). `was` is the groups a contact being
      # updated was in when the page loaded, #apply_groups' own `was`,
      # and none for a new one.
      #
      # Read before the refusals rather than after, so a card sent
      # back to be fixed comes back with its boxes as they were
      # ticked: nothing is staged, and the form is the only record of
      # them until the write.
      choices = store.group_choices
      known = choices.map(&:id)
      ticked = ids_in(r.params["groups"]) & known
      was = ids_in(r.params["was"]) & known
      wanted = ids_in(r.params["named"]).map(&:strip).reject(&:empty?)
      # Everyone's book is one of those boxes, and the only one the
      # write cannot take as an id: on the screen where unticking it
      # matters least — the first card into an empty book — the group
      # does not exist yet, so there is no row and no answer, and the
      # card joins it the way every other create does
      # (Import::Write#call).
      everyone = choices.find { it.name == Group::EVERYONE }
      syncing = everyone.nil? || ticked.include?(everyone.id)

      # N and FN are mandatory (RFC 2426 section 4), so a save blank
      # throughout is refused — the toast is the backstop, the form's
      # name pair (Admin::NamePair) being the browser's own refusal of
      # the same.
      first = r.params["first"].to_s.strip
      middle = r.params["middle"].to_s.strip
      last = r.params["last"].to_s.strip
      if first.empty? && last.empty?
        return card_screen(upload, index, into:, notice: "A contact needs a name.", joined: ticked, named: wanted)
      end

      fields = r.params["birthday"]
      birthday =
        if fields.is_a?(Hash)
          begin
            Admin::CardForm.birthday(fields)
          rescue ArgumentError
            return card_screen(upload, index, into:, notice: "That birthday is not a shape a date can take.",
                                              joined: ticked, named: wanted)
          end
        else
          contact.birthday
        end

      # The snapshot guard the editor always carries, over the staged
      # card rather than a stored one: two tabs open on the same
      # import are the case, and applying this save over the other
      # one's would revert it. Over a fold, it is the contact's own
      # guard too.
      if r.params["etag"].to_s != contact.etag
        return card_screen(upload, index, into:, notice: "This card changed since the page loaded; nothing was saved.",
                                          joined: ticked, named: wanted)
      end

      edited = Admin::CardForm.contact_card(contact, first, middle, last, r.params)
      if target
        # A stored contact, whose birthday the model holds: the contact
        # editor's own save (#apply_edit), down to its one refusal.
        if birthday && carries_own_bday?(contact)
          return card_screen(upload, index, into:,
                             notice: "This contact's card carries its own birthday spelling; nothing was saved.",
                             joined: ticked, named: wanted)
        end

        written = Import::Write.update(store, target.id, edited, birthday:,
                                       joins: ticked - was, leaves: was - ticked, named: wanted)
        # Staged after the write rather than before, unlike a new
        # contact's below: until it lands this row is still the card
        # it arrived as, and staging the contact's card in its place
        # would make that the card a refused or failed save came back
        # to.
        revised[index] = edited
        Import::Staged.update(upload, joined(revised))
        return walk_on(r, upload, index, written, saved, revised.length)
      end

      # The birthday goes back into the card, an import having no
      # model to hold one until it is written. Skipped for a card carrying
      # a BDAY spelling the model does not read: that line stayed in
      # the card (#import_contact, Store#put's own rule), no row
      # rendered for it, and a replace here would delete it.
      unless carries_own_bday?(contact)
        line = birthday&.to_line
        # A birthday with no wire form — a year on its own, a month
        # without its day — is one a vCard 3.0 card cannot spell
        # (docs/plans/2026-08-31-partial-birthdays.md). A stored
        # contact keeps one in the model and serves a card without it;
        # a staged contact has no model, so the card is the whole of
        # what it is, and writing it without the date would lose the
        # date the moment it was typed. Say so instead.
        if birthday && line.nil?
          return card_screen(upload, index,
                             notice: "A card cannot hold a birthday that partial. Import the contact, then add the date on its own page.",
                             joined: ticked, named: wanted)
        end

        edited = edited.replace("BDAY", line ? [line] : [])
      end

      # Staged before it is stored, and kept afterwards: the list
      # renders every row from these bytes, so a row that has come in
      # is still a row the list has to be able to name.
      revised[index] = edited
      Import::Staged.update(upload, joined(revised))
      written = Import::Write.call(store, edited, joins: ticked, named: wanted, everyone: syncing)
      walk_on(r, upload, index, written, saved, revised.length)
    end

    # A row's Save landed, as a new contact or an updated one: the row
    # noted as saved, and the walk on from it. `saved` is the rows
    # saved before this one, and `count` how many the file holds.
    #: (untyped r, String upload, Integer index, Contact written, Hash[String, String] saved, Integer count) -> untyped
    def walk_on(r, upload, index, written, saved, count)
      Import::Staged.record(upload, index.to_s, written.id)

      # The last one: there is nothing left to come back to, so the
      # walk is over rather than a list of rows that all say the same
      # thing.
      return close_walk(r, upload) if saved.length + 1 == count

      # Onto the next row nobody has read, in the file's own order —
      # the walk steps from card to card, a screen between saves
      # having only ever repeated what the list beside every card
      # says. `saved` was read before this write, so the row just
      # written is named here too; a `fetch` rather than a `first`
      # because empty is the case the line above took, and reaching
      # it is a broken assumption rather than a screen to render.
      remaining = (0...count).reject { |i| saved.key?(i.to_s) || i == index }
      r.redirect "/import/#{upload}/#{remaining.fetch(0)}", 303
    end

    # The end of the walk: the file and the walk's own notes gone, and
    # the group the import filed under standing where the walk stood.
    # Reached one way only, by saving the last card there was to save,
    # because that is the only end a walk has. Leaving one needs no
    # screen and no button: the staged file expires on its own
    # (Import::Staged::LIFETIME), and what has come in has come in.
    #
    # There is no screen of its own for what arrived, because the
    # group for the import is that screen and outlives this one — a
    # list of the same contacts, rendered once rather than twice, on a
    # page that is still there tomorrow. A walk whose every card was
    # saved out of that group has none, and the whole book is where
    # they went.
    #: (untyped r, String upload) -> untyped
    def close_walk(r, upload)
      return expired_screen if Import::Staged.read(upload, Import::Staged::SAVED).nil?

      group, _saved = Import::Staged.saved(upload)
      Import::Staged.close(upload)
      filed = store.group_choices.find { it.name == group }

      r.redirect(filed ? "/groups/#{filed.id}" : "/contacts", 303)
    end

    # The import's two readings, or none when it is gone — swept out
    # from under a screen left open overnight, or closed already by
    # the Save that took the last card in. Ordinary enough for the
    # screen to say so and ask for the file again.
    #
    # The re-read parses files this already parsed, which is not a
    # second judgment of them: the bytes are what was staged, and this
    # is the only way back to the cards. A file that read on the way
    # in and will not read now is a broken assumption and raises.
    #: (String upload) -> [Array[VCard], Array[VCard]]?
    def staged_cards(upload)
      original = Import::Staged.read(upload, Import::Staged::ORIGINAL)
      revised = Import::Staged.read(upload, Import::Staged::REVISED)
      return nil if original.nil? || revised.nil?

      [Import::Vcf.cards(original), Import::Vcf.cards(revised)]
    end

    # A staged card read as the contact the editor edits. The id is
    # its place in the file, there being no minted one until it is
    # written, and no group lends a card that is not stored yet a
    # line.
    #
    # The birthday comes out of the card and into the model, which is
    # the split Store#put makes on the way in
    # (docs/plans/2026-09-11-every-birthday-in-the-model.md) — made
    # here too, so the editor renders the same row over an import as
    # over a contact. A BDAY the model does not read stays in the
    # card, that method's own rule.
    #: (VCard card, Integer index) -> Contact
    def import_contact(card, index)
      bdays, rest = card.extract("BDAY")
      birthday = bdays.filter_map { it.property }.filter_map { Birthday.from_property(it) }.first
      Contact.new(id: index.to_s, stored: birthday ? rest : card, birthday:, inherited: [])
    end

    #: (Contact contact) -> bool
    def carries_own_bday?(contact)
      contact.stored.lines.any? { it.names?("BDAY") }
    end

    # Cards back into a file, each keeping its own bytes. A break
    # after any that did not carry one: a file whose last card ends
    # without a newline is still a file, and two cards glued at
    # END:VCARDBEGIN:VCARD is not.
    #: (Array[VCard] cards) -> String
    def joined(cards)
      cards.map { |card|
        bytes = card.to_s
        bytes.end_with?("\n") ? bytes : "#{bytes}\r\n"
      }.join
    end

    # The file part the form sent, and none for a POST carrying no
    # file: #ids_in's shape over an upload, and its reason for being a
    # method — the empty case needs a type, and the signature is where
    # one fits.
    #: (untyped param) -> untyped
    def file_in(param)
      param if param.is_a?(Hash) && param[:tempfile]
    end

    # The screen a file is chosen on, which is all this path is: a
    # walk that has ended has a group to land on rather than a page
    # here saying it ended (#close_walk).
    #: (?notice: String?) -> String
    def import_screen(notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportUpload.call(login: @login, notice:)
    end

    #: () -> String
    def expired_screen
      import_screen(notice: "That import is no longer here. Choose the file again.")
    end
  end
end
