# Security

Licet treats schema text, object ids, and tokens as data.

* Names from a schema or a request are strings. They are not turned into atoms.
* Tokens are base64 JSON. They are not decoded with `:erlang.binary_to_term/1`.
* SQL identifiers are limited to the prefix, which is checked against `^[a-z_][a-z0-9_]{0,62}$` and then interpolated only after that check. Values are query parameters.
* YAML validation files are read with `atoms: false`.
* Object ids are `*` or 1 to 1024 characters from `[A-Za-z0-9/_|=\-+]`.
* A check rejects a wildcard resource. A wildcard is only a subject.
* Writes, imports, preconditions, lookup size, depth, and time are bounded by the instance config.
* The cache stores allowed or denied for one snapshot. It does not store errors, and it is not used inside a transaction or for `:full`.
* Garbage collection will not delete a transaction row that is still inside `gc_window`, so an exact token from that window keeps its snapshot.
* Schema changes that would hide existing tuples are rejected. Narrow a relation only after the tuples that used the old subject types are gone.

Run one Licet instance per prefix. The instance name is chosen by the application, not by request input.

Report security issues privately to the maintainers listed in the repository before opening a public issue.
