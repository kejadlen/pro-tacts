# CardDAV Server Architecture

Phase 1: Read-only CardDAV server for Apple Contacts.

## RFCs

| RFC | Name | Purpose |
|-----|------|---------|
| [RFC 4918](https://datatracker.ietf.org/doc/html/rfc4918) | WebDAV | HTTP extensions for distributed authoring |
| [RFC 6352](https://datatracker.ietf.org/doc/html/rfc6352) | CardDAV | vCard extensions to WebDAV |
| [RFC 6350](https://datatracker.ietf.org/doc/html/rfc6350) | vCard 4.0 | Contact data format |
| [RFC 3253](https://datatracker.ietf.org/doc/html/rfc3253) | REPORT | Required for addressbook-multiget |

## HTTP Methods

### Phase 1 (read-only)

| Method | Purpose |
|--------|---------|
| `OPTIONS` | Advertise capabilities |
| `PROPFIND` | Discovery + collection listing |
| `GET` | Retrieve individual vCards |
| `REPORT` | addressbook-multiget (batch fetch) |

### Deferred

| Method | Purpose |
|--------|---------|
| `PUT` | Create/update vCards |
| `DELETE` | Remove vCards |
| `MKCOL` | Create address books |
| `PROPPATCH` | Modify properties |
| `addressbook-query` | Search/filter contacts |

## URL Structure

```
/.well-known/carddav        → redirect to /principal/
/principal/                 → user's principal resource
/addressbooks/              → addressbook-home-set
/addressbooks/contacts/     → the address book collection
/addressbooks/contacts/{id}.vcf → individual vCard
```

User identity from auth, not URL path.

## Discovery Flow

```
1. OPTIONS /.well-known/carddav
   → 301 Redirect to /principal/

2. OPTIONS /principal/
   → 200 OK
   → DAV: 1, 3, addressbook

3. PROPFIND /principal/ (Depth: 0)
   → current-user-principal: /principal/
   → addressbook-home-set: /addressbooks/

4. PROPFIND /addressbooks/ (Depth: 1)
   → Lists /addressbooks/contacts/ as type addressbook

5. REPORT /addressbooks/contacts/ (addressbook-multiget)
   → Returns vCards
```

### Key Properties

| Property | Location | Value |
|----------|----------|-------|
| `current-user-principal` | `/principal/` | `/principal/` |
| `addressbook-home-set` | `/principal/` | `/addressbooks/` |
| `resourcetype` | `/addressbooks/contacts/` | collection, addressbook |
| `displayname` | `/addressbooks/contacts/` | "Contacts" |
| `getctag` | `/addressbooks/contacts/` | change tag for sync |

## Storage

### Directory Structure

```
data/
└── contacts/
    ├── kqmtnwpxlrvszoyp.kdl
    ├── nzxwvtslqpomkrny.kdl
    └── plokmnzxwvtsrqky.kdl
```

### Contact File Format (KDL)

One bare KDL document per file — no `contact {}` wrapper, since the
file itself is the contact:

```kdl
name "John Smith"
phone "+1-555-1234" type="mobile"
email "john@example.com"
```

### Contact IDs

- 16 characters using k-z (16 letters)
- 64 bits of entropy
- Filename is the ID: `{id}.kdl`
- Maps to vCard UID

### Change Detection

- `getctag`: hash of directory listing or newest mtime
- `getetag`: mtime or content hash of .kdl file

### Deferred

- Per-user addressbook files (`addressbooks/{user}.kdl`)
- Groups with shared attributes
- Database migration

## Roda Architecture

### File Structure

```
lib/
└── pro_tacts/
    └── app.rb
```

Extract classes when needed.

### Routing

```ruby
module ProTacts
  class App < Roda
    plugin :all_verbs

    route do |r|
      r.on ".well-known/carddav" do
        r.redirect "/principal/"
      end

      r.on "principal" do
        r.is do
          r.options { dav_options }
          r.propfind { principal_propfind(r) }
        end
      end

      r.on "addressbooks" do
        r.is do
          r.propfind { home_propfind(r) }
        end

        r.on "contacts" do
          r.is do
            r.options { dav_options }
            r.propfind { collection_propfind(r) }
            r.report { addressbook_multiget(r) }
          end

          r.on String do |id|
            r.get { serve_vcard(id) }
          end
        end
      end
    end
  end
end
```

## Translation

KDL → vCard on read. The server parses KDL contact files into vCard 3.0
(`lib/pro_tacts/vcard.rb`), the version Apple clients speak.
