# Type checking with inline RBS and Steep

2026-08-20. Types for `lib/`, written as comments in the code rather than
as a parallel signature tree, and checked by `rake steep`.

## The shape

A method's type sits above it, in the comment a reader is already
looking at:

```ruby
#: (KDL::Document document, uid: String) -> String
def render(document, uid:)
```

`# @rbs` carries what a method type cannot — instance variables, and the
`skip` that hands a declaration over to `sig/`. A trailing `#:` gives a
constant its type or asserts one the checker cannot infer.

`rake steep` runs the check. It is not part of the default task: the
suite stays the thing `rake` runs, and this is a second opinion, not a
gate the tests wait on. Moving it under `default` is a one-line change
if that turns out to be the wrong split.

## Why comments rather than a sig tree

A parallel `sig/**/*.rbs` is a second copy of every method in the
project, and the two drift the moment anything is renamed. Everything
this project keeps — the RFC citations, the reasons a property is in a
response — is already written next to the code it explains, and types
are the same kind of note.

## What sig/ is still for

Five things the inline syntax cannot say. Each file there names the one
that put it there:

| File | Limit |
|---|---|
| `sig/gems/*.rbs` | kdl, nokogiri, rack, roda and sentry-ruby ship no signatures |
| `sig/pro_tacts/contact.rbs`, `addressbook.rbs` | `class X < Data.define(...)` has no constant super class to read |
| `sig/pro_tacts/vcard.rbs` | `module_function` has no inline spelling; `extend VCard` says it |
| `sig/pro_tacts.rbs` | `class << self` is not read |
| `sig/roda/plugins/dav_verbs.rbs` | methods defined by `class_eval` on a string |

The Data classes are the only real loss: their whole signature lives in
`sig/`, away from the code, because `@rbs skip` takes the method types
with it. Their bodies are still checked against it.

## Why the gem signatures are hand-written

gem_rbs_collection would mean `rbs collection install`, a second
lockfile, and a network fetch before the checker can run — and it
carries neither roda nor kdl, which are the two that matter here. Each
stub is a few dozen lines covering only what this app calls. Anything
called that is missing from one is a type error rather than a silent
`untyped`, which is the point.

Two of them narrow reality on purpose, and say so where they do it:
Sentry events stay `untyped`, because `SentryScrubber` feature-detects
its way through whatever `before_send` hands it, and Roda's matchers
stay `untyped`, because the vocabulary is open and the block arguments
depend on which matcher matched. `r.get String do |filename|` yields an
untyped filename.

## Steep is pinned to a prerelease

`steep 2.0.0` parses Ruby as 3.3, where `it` is a method call rather
than the block parameter, so every block in `lib/` fails. `2.1.0.dev.1`
is the first release parsing 3.4. Unpin it when 2.1.0 ships.

## Encoding

RBS reads source files in the default external encoding, so under a C
locale every em dash in these comments is an invalid byte and the check
dies inside the parser. `rake steep` sets `-EUTF-8` for the run. This is
the same footgun the ASCII-only rule in `config.ru` exists for.

## What the checker found

- `Nokogiri::XML` returns a document with no root when the body is not
  XML, and the REPORT handler read `doc.root.name` straight out. It
  raises now, which is the same 500 with a legible reason.
- Two spots reported the first unknown key with `reject(...).first`,
  which is nil-shaped to a checker. `find` says the same thing directly.
- `Regexp.last_match(1)` after a `when /\AHTTP_(.+)\z/` is `String?`
  even where the match cannot have failed; `key.delete_prefix("HTTP_")`
  is the same value with no nil in it.

None of these were live bugs. The nil-root one was the closest.

## What is not checked

`test/`, the `Rakefile` and `config.ru`. Tests are already the check on
themselves, and typing them means signatures for minitest and rack-test
before anything is learned.

One thing to know about the boundary: a file Steep cannot parse is
skipped without a word, so a syntax error reads as a clean check. `rake`
is what catches that.
