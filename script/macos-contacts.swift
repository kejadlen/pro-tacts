// Reads and deletes this Mac's Contacts for an import plan
// (docs/plans/2026-09-16-importing-from-macos.md, "Reading the Mac" and
// "Removing the originals").
//
//   swift script/macos-contacts.swift read [limit]
//   swift script/macos-contacts.swift show <identifier>...
//   swift script/macos-contacts.swift delete <identifier>...
//
// read prints one JSON object per person in the iCloud account, companies
// skipped, in Contacts.app's own order: the identifier, the framework's
// vCard, every fetched key, and the note, which only AppleScript will give
// up. Cards are read unmerged, so a contact linked to a card in another
// account (Monica, or pro-tacts itself) is this account's card alone.
//
// show prints those same objects for the identifiers it is given, leaving
// out the ones this Mac no longer has; delete deletes them, and an
// identifier it no longer has is already deleted.

import Contacts
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("macos-contacts: \(message)\n".utf8))
  exit(1)
}

// Every key but the note, which the framework strips from an unentitled
// fetch without an error.
let keys: [String] = [
  CNContactIdentifierKey, CNContactTypeKey,
  CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
  CNContactPreviousFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey,
  CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
  CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
  CNContactPhoneticOrganizationNameKey,
  CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
  CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
  CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
  CNContactUrlAddressesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
  CNContactInstantMessageAddressesKey,
]

func json(_ value: Any?) -> Any {
  switch value {
  case nil: return NSNull()
  case let string as String: return string
  case let data as Data: return data.base64EncodedString()
  case let number as NSNumber: return number
  case let components as DateComponents:
    var fields: [String: Any] = [:]
    if let calendar = components.calendar { fields["calendar"] = calendar.identifier.debugDescription }
    if let era = components.era { fields["era"] = era }
    if let year = components.year { fields["year"] = year }
    if let month = components.month { fields["month"] = month }
    if let day = components.day { fields["day"] = day }
    if let leap = components.isLeapMonth { fields["leap_month"] = leap }
    return fields
  // A CNLabeledValue's type parameter is an Objective-C lightweight
  // generic, so its parts are read by key rather than through a cast.
  case let labeled as [NSObject] where labeled.allSatisfy({ $0 is CNLabeledValue<NSString> }):
    return labeled.map {
      ["identifier": json($0.value(forKey: "identifier")), "label": json($0.value(forKey: "label")), "value": json($0.value(forKey: "value"))]
    }
  case let phone as CNPhoneNumber: return phone.stringValue
  case let address as CNPostalAddress:
    return [
      "street": address.street, "sub_locality": address.subLocality, "city": address.city,
      "sub_administrative_area": address.subAdministrativeArea, "state": address.state,
      "postal_code": address.postalCode, "country": address.country, "iso_country_code": address.isoCountryCode,
    ]
  case let relation as CNContactRelation: return relation.name
  case let profile as CNSocialProfile:
    return [
      "url": profile.urlString, "username": profile.username,
      "user_identifier": profile.userIdentifier, "service": profile.service,
    ]
  case let im as CNInstantMessageAddress: return ["username": im.username, "service": im.service]
  default: fail("no JSON spelling for a \(type(of: value!))")
  }
}

// Every person's note by identifier, in one Apple event, and every
// identifier AppleScript knows, so a contact it spells differently fails
// rather than reading as one with no note.
func notes() -> (ids: Set<String>, notes: [String: String]) {
  let source = "tell application \"Contacts\" to get {id, note} of every person"
  var error: NSDictionary?
  guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
    fail("reading notes through AppleScript: \(error ?? [:])")
  }
  guard let ids = result.atIndex(1), let notes = result.atIndex(2), ids.numberOfItems == notes.numberOfItems else {
    fail("AppleScript answered notes in an unexpected shape")
  }
  var known: Set<String> = []
  var byId: [String: String] = [:]
  if ids.numberOfItems > 0 {
    for index in 1...ids.numberOfItems {
      guard let id = ids.atIndex(index)?.stringValue else { fail("a person with no id") }
      known.insert(id)
      if let note = notes.atIndex(index)?.stringValue { byId[id] = note }
    }
  }
  return (known, byId)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: macos-contacts.swift read [limit] | show <identifier>... | delete <identifier>..."
guard let command = arguments.first, ["read", "show", "delete"].contains(command) else { fail(usage) }
let rest = Array(arguments.dropFirst())

var limit: Int? = nil
if command == "read" {
  if let first = rest.first {
    guard let n = Int(first), n > 0 else { fail("a limit is a positive number") }
    limit = n
  }
} else {
  guard !rest.isEmpty else { fail(usage) }
}

let store = CNContactStore()
let icloud: [CNContainer]
do {
  icloud = try store.containers(matching: nil).filter { $0.name == "iCloud" }
} catch {
  fail("listing accounts: \(error)")
}
guard icloud.count == 1 else { fail("found \(icloud.count) accounts named iCloud, and reads exactly one") }

let request = CNContactFetchRequest(
  keysToFetch: keys.map { $0 as NSString } + [CNContactVCardSerialization.descriptorForRequiredKeys()])
request.predicate =
  command == "read"
  ? CNContact.predicateForContactsInContainer(withIdentifier: icloud[0].identifier)
  // An identifier names one card, and the named ones were read out of
  // iCloud by an earlier run of this script.
  : CNContact.predicateForContacts(withIdentifiers: rest)
// Merged contacts carry identifiers no card has, which AppleScript cannot
// find and a delete could not name.
request.unifyResults = false
request.sortOrder = .userDefault

var people: [CNContact] = []
do {
  try store.enumerateContacts(with: request) { contact, stop in
    guard contact.contactType == .person else { return }
    people.append(contact)
    if let limit, people.count >= limit { stop.pointee = true }
  }
} catch {
  fail("reading contacts: \(error)")
}

if command == "delete" {
  // One save request for the batch: a delete of a contact this Mac no
  // longer has is a delete that already happened, so the identifiers that
  // matched nothing are left alone.
  let request = CNSaveRequest()
  for contact in people {
    guard let mutable = contact.mutableCopy() as? CNMutableContact else { fail("\(contact.identifier) will not copy") }
    request.delete(mutable)
  }
  if !people.isEmpty {
    do {
      try store.execute(request)
    } catch {
      fail("deleting \(people.count) contacts: \(error)")
    }
  }
  exit(0)
}

let (noted, noteById) = notes()
for contact in people {
  guard noted.contains(contact.identifier) else {
    fail("AppleScript has no person \(contact.identifier), so its note cannot be read")
  }
  for key in keys where !contact.isKeyAvailable(key) {
    fail("\(key) came back unavailable for \(contact.identifier)")
  }
  var fields: [String: Any] = [:]
  for key in keys { fields[key] = json(contact.value(forKey: key)) }

  let vcard: String
  do {
    vcard = String(decoding: try CNContactVCardSerialization.data(with: [contact]), as: UTF8.self)
  } catch {
    fail("serializing \(contact.identifier): \(error)")
  }

  let object: [String: Any] = [
    "identifier": contact.identifier, "vcard": vcard, "contact": fields, "note": json(noteById[contact.identifier]),
  ]
  let line = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(line + Data("\n".utf8))
}
