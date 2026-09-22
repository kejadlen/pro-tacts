require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/import_groups"
require "pro_tacts/admin/import_original"
require "pro_tacts/admin/import_review"
require "pro_tacts/admin/import_sidebar"
require "pro_tacts/admin/import_upload"
require "pro_tacts/birthday"
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
    # Three screens, because an import is a walk rather than a
    # submission: choose the file, read what the whole of it is
    # losing, and open any of its contacts beside the card it arrived
    # as. The Save on that last screen is the import of that one
    # contact — not a note kept until a confirm at the end — so the
    # walk's list says what is in the book and what is not yet, and
    # what is left when the walk stops is only the part nobody looked
    # at. That list is a sidebar rather than a screen of its own
    # (Admin::ImportSidebar): it stands beside the two later screens
    # both, so opening a row never costs your place in it.
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
        # Before the index below, and distinguishable from one: a
        # path segment is what says which request this is, not which
        # fields a form happened to carry.
        r.post "done" do
          finish_import(upload)
        end

        r.is do
          r.get do
            review_screen(upload)
          end
        end

        # The contact's place in the file is its name here, until its
        # own Save mints one. The file's own order is the one thing
        # about a card that cannot change under the walk: the editor's
        # save rewrites a card in place and never adds or removes one.
        r.on Integer do |index|
          r.is do
            r.get do
              open_card(r, upload, index)
            end

            r.post do
              save_card(r, upload, index)
            end
          end
        end
      end
    end

    private

    # The upload's own POST: the file read and judged whole before
    # anything is staged, the old `execute`'s rule that a source which
    # will not read brings in nothing. What it stages is both readings —
    # the file as it arrived, and the cards pared to what this book
    # shows — and then it is the review screen's walk.
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
      # Straight to the first contact rather than to the screen about
      # the file: the walk is the point, and a list that has just been
      # built from a file nobody has looked at yet is a stop on the
      # way to the same place. What the whole file is losing is on the
      # screen that list links back to, and the list itself stands
      # beside every card anyway (Admin::ImportSidebar). A file with
      # no contacts in it has no first one to open.
      #
      # A 303, the other writes' answer, because what follows is a
      # walk: every screen of it is a GET a back button can revisit.
      r.redirect(cards.empty? ? "/import/#{id}" : "/import/#{id}/0", 303)
    end

    # What the whole file is losing, what it is coming in under, and
    # the way to stop. The contacts themselves are the sidebar beside
    # it, which every screen of the walk carries.
    #: (String upload, ?notice: String?) -> String
    def review_screen(upload, notice: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, revised = staged
      group, saved = Import::Staged.saved(upload)

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportReview.call(
        upload:,
        contacts: revised.length,
        saved: saved.length,
        unknown: Import::Vcf.unknown(originals),
        group:,
        sidebar: walk_sidebar(upload, originals, revised, saved),
        notice:,
      )
    end

    # The walk's list of contacts, as every screen of it shows them:
    # the contact each card will be written as, how many of its
    # original's lines are not coming with it, and which rows are in
    # the book already. `current` is the row whose screen is open.
    #: (String upload, Array[VCard] originals, Array[VCard] revised, Hash[String, String] saved, ?current: Integer?) -> Admin::ImportSidebar
    def walk_sidebar(upload, originals, revised, saved, current: nil)
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
    # already saved. The editor here writes into the import, and an
    # import that has already written this one has nothing left to say
    # about it: from then on it is a contact, edited where every other
    # contact is.
    #: (untyped r, String upload, Integer index) -> untyped
    def open_card(r, upload, index)
      _group, saved = Import::Staged.saved(upload)
      contact = saved[index.to_s]
      return r.redirect "/contacts/#{contact}" if contact

      card_screen(upload, index)
    end

    # One contact, the card it arrived as beside the card that is
    # coming in. The right-hand half is the contact editor itself, not a
    # copy of it: a field the two disagreed about would be a field an
    # import writes and an edit cannot undo.
    #
    # `joined` and `named` are the groups a refused save had ticked,
    # and none on the way in: nothing is staged between screens, the
    # Save that would have written an answer being the Save that
    # writes the contact, so a card opened afresh is asked the
    # question with the defaults ticked (#import_picker) rather than
    # with an earlier answer read back.
    #: (String upload, Integer index, ?notice: String?, ?joined: Array[String]?, ?named: Array[String]?) -> String?
    def card_screen(upload, index, notice: nil, joined: nil, named: nil)
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

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(
        contact: import_contact(card, index),
        notice:,
        action: "/import/#{upload}/#{index}",
        back: ["/import/#{upload}", "the import"],
        # The submit says where the card is going, because it is not
        # there yet: this is the one editor in the app whose Save
        # creates the record rather than amending it, and the row
        # beside it wears the unsaved rail until it has been pressed
        # (Admin::ImportSidebar).
        save: "save to the book",
        aside: Admin::ImportOriginal.new(card: original, dropped: Import::Vcf.read(original).dropped),
        fields: import_picker(group, joined, named),
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
    #: (String group, Array[String]? joined, Array[String]? named) -> Admin::ImportGroups
    def import_picker(group, joined, named)
      choices = store.group_choices
      lot = group.empty? ? nil : choices.find { it.name == group }
      everyone = choices.find { it.name == Store::EVERYONE }
      Admin::ImportGroups.new(
        groups: choices,
        joined: joined || [everyone&.id, lot&.id].compact,
        named: named || [(group unless lot || group.empty?)].compact,
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
      # A Save pressed twice, or a back button onto the screen of a
      # contact that is already in the book: a second write here would
      # be a second contact rather than an edit of the first, there
      # being no id in the file to recognise it by.
      stored = saved[index.to_s]
      return r.redirect "/contacts/#{stored}", 303 if stored

      contact = import_contact(card, index)

      # The groups ride in the same form and are written by the same
      # Save (Admin::ImportGroups): a card the walk has looked at is
      # decided about in both ways at once. Only ids naming a group,
      # #apply_groups' own rule, and the boxes are the whole answer —
      # none ticked is none joined, the group for the import included,
      # which is a box like any other here (#import_picker). A name
      # typed into the filter joins the names already standing for
      # this contact, and is made by the write below
      # (Import::Write#group_id).
      #
      # Read before the refusals rather than after, so a card sent
      # back to be fixed comes back with its boxes as they were
      # ticked: nothing is staged, and the form is the only record of
      # them until the write.
      choices = store.group_choices
      ticked = ids_in(r.params["groups"]) & choices.map(&:id)
      standing = ids_in(r.params["named"]).map(&:strip).reject(&:empty?)
      fresh = r.params["new"].to_s.strip
      wanted = (fresh.empty? ? standing : standing + [fresh]).uniq
      # Everyone's book is one of those boxes, and the only one the
      # write cannot take as an id: on the screen where unticking it
      # matters least — the first card into an empty book — the group
      # does not exist yet, so there is no row and no answer, and the
      # card joins it the way every other create does
      # (Import::Write#call).
      everyone = choices.find { it.name == Store::EVERYONE }
      syncing = everyone.nil? || ticked.include?(everyone.id)

      # N and FN are mandatory (RFC 2426 section 4), so a save blank
      # throughout is refused — the toast is the backstop, the form's
      # name pair (Admin::NamePair) being the browser's own refusal of
      # the same.
      first = r.params["first"].to_s.strip
      middle = r.params["middle"].to_s.strip
      last = r.params["last"].to_s.strip
      if first.empty? && last.empty?
        return card_screen(upload, index, notice: "A contact needs a name.", joined: ticked, named: wanted)
      end

      fields = r.params["birthday"]
      birthday =
        if fields.is_a?(Hash)
          begin
            Admin::CardForm.birthday(fields)
          rescue ArgumentError
            return card_screen(upload, index, notice: "That birthday is not a shape a date can take.",
                                              joined: ticked, named: wanted)
          end
        else
          contact.birthday
        end

      # The snapshot guard the editor always carries, over the staged
      # card rather than a stored one: two tabs open on the same
      # import are the case, and applying this save over the other
      # one's would revert it.
      if r.params["etag"].to_s != contact.etag
        return card_screen(upload, index, notice: "This card changed since the page loaded; nothing was saved.",
                                          joined: ticked, named: wanted)
      end

      edited = Admin::CardForm.contact_card(contact, first, middle, last, r.params)
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
      Import::Staged.record(upload, index.to_s, written.id)

      # The last one: there is nothing left to come back to, so the
      # import ends here rather than on a list of rows that all say
      # the same thing and a button under them.
      return finish_import(upload) if saved.length + 1 == revised.length

      r.redirect "/import/#{upload}", 303
    end

    # The end of the walk: what it wrote, listed, and the file and the
    # walk's own notes gone. Reached by saving the last card or by
    # saying so on the list, and the rows nobody opened are simply
    # left behind — the file they came from is the importer's own, and
    # this copy of it goes with the button.
    #
    # Answered with the page rather than a 303, and has to be: the
    # staged import is gone, so the re-submission a back button offers
    # has nothing left to finish, and there is no other page holding
    # what just arrived.
    #: (String upload) -> String
    def finish_import(upload)
      return expired_screen if Import::Staged.read(upload, Import::Staged::SAVED).nil?

      _group, saved = Import::Staged.saved(upload)
      # In the file's own order rather than the order the walk got to
      # them in, which is the order the list they are read back
      # instead of was in.
      imported = saved.keys.sort_by(&:to_i).filter_map { store.contact(saved.fetch(it)) }
      Import::Staged.close(upload)

      import_screen(imported:)
    end

    # The import's two readings, or none when it is gone — swept out
    # from under a screen left open overnight, or finished already, a
    # second press finding what the first removed. Ordinary enough
    # for the screen to say so and ask for the file again.
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

    # The screen a file is chosen on, and the page a finished import
    # answers with.
    #: (?imported: Array[Contact]?, ?notice: String?) -> String
    def import_screen(imported: nil, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportUpload.call(imported:, notice:)
    end

    #: () -> String
    def expired_screen
      import_screen(notice: "That import is no longer here. Choose the file again.")
    end
  end
end
