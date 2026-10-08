# Schema language

Licet accepts this subset of `.zed`.

* `definition`, `relation`, and `permission`
* `+`, `&`, `-`, and `->`
* Parentheses
* Wildcards written `user:*`
* Userset subjects written `team#member`
* `use expiration` once at the top of the file
* `with expiration` on a subject type that may carry an expiry
* `//` comments
* Object types with a slash, such as `docs/folder`

Names are lowercase and 3 to 64 characters: a letter, then letters, digits, or underscores, ending with a letter or digit. Object types may be several such segments joined by `/`, up to 128 characters in total.

These SpiceDB features are rejected:

* `caveat`
* `.all()` and `.any()`
* `self`
* `nil`

`use expiration` is required before any `with expiration`. A subject type without `with expiration` cannot be written with an expiry. A wildcard subject allows only the wildcard id `*`, not a concrete id of that type.

Errors from `Licet.Schema.parse/1` include a line and column. `Licet.Schema.to_zed/1` prints a schema that parses back to the same definitions. Comments are not preserved.
