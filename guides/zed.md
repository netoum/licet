# Schema language

Licet accepts this subset of `.zed`.

* `definition`, `relation`, and `permission`
* `+`, `&`, `-`, and `->`
* `relation.any(permission)`, the same as `relation->permission`
* `relation.all(permission)`, which grants only when every related object grants `permission`; with no related object it grants nothing
* `nil`, the empty set
* Parentheses
* Wildcards written `user:*`
* Userset subjects written `team#member`
* `use expiration` once at the top of the file
* `with expiration` on a subject type that may carry an expiry
* `//` comments
* Object types with a slash, such as `docs/folder`

Names are lowercase and 3 to 64 characters: a letter, then letters, digits, or underscores, ending with a letter or digit. Object types may be several such segments joined by `/`, up to 128 characters in total.

Operators bind as in SpiceDB: `->` and `.any()`/`.all()` first, then `+`, then `&`, then `-`. So `a - b & c` is `a - (b & c)` and `a & b + c` is `a & (b + c)`. Operators of the same kind group to the left.

The left side of an arrow must be a relation. Its right side must be defined on at least one of that relation's subject types. Subject types that do not define it contribute nothing. SpiceDB accepts the same schemas and only lints the case where no subject type defines the name; Licet rejects that case. An arrow follows each row's subject object and ignores a subject relation, so `relation parent: folder#viewer` with `permission view = parent->owner` checks `owner` on the folder.

These SpiceDB features are rejected:

* `caveat`
* `self`

`use expiration` is required before any `with expiration`. A subject type without `with expiration` cannot be written with an expiry. A wildcard subject allows only the wildcard id `*`, not a concrete id of that type.

Errors from `Licet.Schema.parse/1` include a line and column. `Licet.Schema.to_zed/1` prints a schema that parses back to the same definitions. Comments are not preserved.
