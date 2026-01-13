# CardDAV Protocol Reference

Examples and formats from the RFCs for implementation reference.

## XML Namespaces

```xml
xmlns:D="DAV:"
xmlns:C="urn:ietf:params:xml:ns:carddav"
```

## OPTIONS

**Request:**
```http
OPTIONS /principal/ HTTP/1.1
Host: carddav.example.com
```

**Response:**
```http
HTTP/1.1 200 OK
DAV: 1, 3, addressbook
Allow: OPTIONS, GET, PROPFIND, REPORT
```

## PROPFIND

### Request Format

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>
```

### Request with CardDAV Properties

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:prop>
    <D:current-user-principal/>
    <C:addressbook-home-set/>
  </D:prop>
</D:propfind>
```

### 207 Multi-Status Response

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/principal/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Alice</D:displayname>
        <D:resourcetype/>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
```

### Response with Multiple Properties (some missing)

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/principal/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Alice</D:displayname>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop>
        <D:getcontentlength/>
      </D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
```

## Discovery Properties

### current-user-principal

```xml
<D:current-user-principal xmlns:D="DAV:">
  <D:href>/principal/</D:href>
</D:current-user-principal>
```

### addressbook-home-set

```xml
<C:addressbook-home-set xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:href>/addressbooks/</D:href>
</C:addressbook-home-set>
```

### resourcetype (for address book collection)

```xml
<D:resourcetype xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:collection/>
  <C:addressbook/>
</D:resourcetype>
```

### supported-address-data

```xml
<C:supported-address-data xmlns:C="urn:ietf:params:xml:ns:carddav">
  <C:address-data-type content-type="text/vcard" version="4.0"/>
</C:supported-address-data>
```

## REPORT: addressbook-multiget

### Request

```xml
<?xml version="1.0" encoding="utf-8" ?>
<C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:prop>
    <D:getetag/>
    <C:address-data/>
  </D:prop>
  <D:href>/addressbooks/contacts/kqmtnwpxlrvszoyp.vcf</D:href>
  <D:href>/addressbooks/contacts/nzxwvtslqpomkrny.vcf</D:href>
</C:addressbook-multiget>
```

### Request with Specific vCard Properties

```xml
<?xml version="1.0" encoding="utf-8" ?>
<C:addressbook-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:prop>
    <D:getetag/>
    <C:address-data>
      <C:prop name="VERSION"/>
      <C:prop name="UID"/>
      <C:prop name="FN"/>
      <C:prop name="EMAIL"/>
    </C:address-data>
  </D:prop>
  <D:href>/addressbooks/contacts/kqmtnwpxlrvszoyp.vcf</D:href>
</C:addressbook-multiget>
```

### Response

```xml
<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
  <D:response>
    <D:href>/addressbooks/contacts/kqmtnwpxlrvszoyp.vcf</D:href>
    <D:propstat>
      <D:prop>
        <D:getetag>"abc123"</D:getetag>
        <C:address-data>BEGIN:VCARD
VERSION:4.0
UID:kqmtnwpxlrvszoyp
FN:John Smith
EMAIL:john@example.com
END:VCARD
</C:address-data>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
```

## vCard 4.0 Format

### Minimal vCard

```
BEGIN:VCARD
VERSION:4.0
UID:kqmtnwpxlrvszoyp
FN:John Smith
END:VCARD
```

### Full Example

```
BEGIN:VCARD
VERSION:4.0
UID:kqmtnwpxlrvszoyp
FN:John Smith
N:Smith;John;;;
TEL;TYPE=mobile:+1-555-1234
TEL;TYPE=work:+1-555-5678
EMAIL;TYPE=home:john@example.com
EMAIL;TYPE=work:jsmith@work.com
ADR;TYPE=home:;;123 Main St;Springfield;IL;62701;USA
END:VCARD
```

### Property Reference

| Property | Required | Format |
|----------|----------|--------|
| `BEGIN` | Yes | `BEGIN:VCARD` |
| `VERSION` | Yes | `VERSION:4.0` |
| `UID` | Yes | Unique identifier |
| `FN` | Yes | Formatted name (display name) |
| `END` | Yes | `END:VCARD` |
| `N` | No | `family;given;additional;prefix;suffix` |
| `TEL` | No | Phone with optional TYPE |
| `EMAIL` | No | Email with optional TYPE |
| `ADR` | No | `pobox;ext;street;city;region;postal;country` |

### TYPE Values

- TEL: `work`, `home`, `mobile`, `fax`, `pager`
- EMAIL: `work`, `home`
- ADR: `work`, `home`

## KDL to vCard Mapping

### KDL Input

```kdl
contact {
    name "John Smith"
    phone "+1-555-1234" type="mobile"
    phone "+1-555-5678" type="work"
    email "john@example.com" type="home"
    address type="home" {
        street "123 Main St"
        city "Springfield"
        state "IL"
        zip "62701"
        country "USA"
    }
}
```

### vCard Output

```
BEGIN:VCARD
VERSION:4.0
UID:kqmtnwpxlrvszoyp
FN:John Smith
TEL;TYPE=mobile:+1-555-1234
TEL;TYPE=work:+1-555-5678
EMAIL;TYPE=home:john@example.com
ADR;TYPE=home:;;123 Main St;Springfield;IL;62701;USA
END:VCARD
```

## HTTP Headers

### Request Headers

| Header | Value | When |
|--------|-------|------|
| `Depth` | `0`, `1`, `infinity` | PROPFIND |
| `Content-Type` | `application/xml; charset=utf-8` | PROPFIND, REPORT |

### Response Headers

| Header | Value | When |
|--------|-------|------|
| `DAV` | `1, 3, addressbook` | OPTIONS |
| `Content-Type` | `application/xml; charset=utf-8` | 207 responses |
| `Content-Type` | `text/vcard; charset=utf-8` | GET vCard |
| `ETag` | `"hash"` | GET, in propstat |

## Status Codes

| Code | Meaning |
|------|---------|
| 200 | OK |
| 207 | Multi-Status (contains per-resource status) |
| 301 | Redirect (for .well-known) |
| 404 | Not Found |
| 405 | Method Not Allowed |
