# Schema language

Licet reads the schema language of [SpiceDB](https://authzed.com/docs/spicedb/concepts/schema), usually stored in a `.zed` file. This page is the reference for everything Licet accepts. [Modeling permissions](modeling.md) shows how to use it.

## Definitions

A schema is a list of definitions. Each `definition` declares an object type and contains its relations and permissions:

```zed
definition user {}

definition document {
  relation owner: user
  permission edit = owner
}
```

A type name may contain a slash to group related types, such as `docs/folder`.

## Names

Type, relation, and permission names are lowercase and 3 to 64 characters long. They start with a letter, end with a letter or digit, and contain only letters, digits, and underscores. A type name may be several such segments joined by `/`, up to 128 characters in total.

Relations and permissions share one namespace per definition, so a definition can't have a relation and a permission with the same name.

## Relations

A relation lists the subject types it accepts, separated by `|`:

```zed
relation viewer: user | user:* | team#member
```

| Subject type | Accepts | Example relationship |
| --- | --- | --- |
| `user` | one object of that type | `document:1#viewer@user:ada` |
| `user:*` | the wildcard, meaning every object of that type | `document:1#viewer@user:*` |
| `team#member` | a userset: every subject of that relation | `document:1#viewer@team:eng#member` |

A relationship whose subject doesn't match one of the listed types is rejected when it's written, with `:invalid_relationship`. A wildcard type accepts only the id `*`.

### Expiration

Relationships can carry an expiry. Enable it with `use expiration` at the top of the file, then add `with expiration` to the subject types that may expire:

```zed
use expiration

definition document {
  relation viewer: user | user with expiration
}
```

```text
document:1#viewer@user:guest[expiration:2027-01-01T00:00:00Z]
```

`with expiration` without `use expiration` is an error, and so is an expiry on a subject type that doesn't allow one. An expired relationship stops counting at its expiry time.

## Permissions

A permission is an expression over relations and other permissions of the same definition:

```zed
permission view = viewer + edit + parent->view
```

| Syntax | Meaning |
| --- | --- |
| `a + b` | union: granted by either |
| `a & b` | intersection: granted by both |
| `a - b` | exclusion: granted by `a` and not by `b` |
| `rel->perm` | arrow: granted by `perm` on any object in `rel` |
| `rel.any(perm)` | the same as `rel->perm` |
| `rel.all(perm)` | granted by `perm` on every object in `rel`; nothing when `rel` is empty |
| `nil` | the empty set: grants nothing |
| `( ... )` | grouping |

### Arrows

The left side of an arrow must be a relation of the same definition. The right side must be a relation or permission defined on at least one of that relation's subject types. Subject types that don't define it contribute nothing.

An arrow follows each relationship's subject object and ignores its subject relation. With `relation parent: folder#viewer` and `permission view = parent->owner`, a relationship `document:1#parent@folder:a#viewer` makes the check ask `owner` on `folder:a`.

Wildcard subjects are never followed by an arrow.

### Precedence

Operators bind the same way as in SpiceDB, tightest first:

1. `->`, `.any()`, `.all()`
2. `+`
3. `&`
4. `-`

Operators of the same kind group to the left. So `a - b & c` is `a - (b & c)`, and `a & b + c` is `a & (b + c)`.

### Recursion

A permission may refer to itself through an arrow, as in `permission view = viewer + parent->view`, which walks a hierarchy. A permission that refers to itself without an arrow, such as `permission view = view`, is rejected. At check time, a walk that revisits the same object and permission stops with `:cycle`, and one longer than `max_depth` hops stops with `:depth_exceeded`.

## Comments

`//` starts a comment that runs to the end of the line.

## Not supported

These SpiceDB features are rejected with an error naming them:

* `caveat` definitions and caveated subject types
* `use self` and `self`

See [Limitations](limitations.md) for the reasons and alternatives.

## Differences from SpiceDB

Licet rejects an arrow whose right side isn't defined on any subject type of its relation. SpiceDB accepts that schema and reports a lint warning.

## Errors and printing

`Licet.Schema.parse/1` returns `{:error, %Licet.Error{reason: :invalid_schema}}` with the line and column of the problem in `details`. `Licet.Schema.to_zed/1` prints a parsed schema back as text that parses to the same definitions. Comments aren't preserved.
