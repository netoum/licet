# Modeling permissions

A Licet schema is a small program that turns stored relationships into permissions. This guide builds one up pattern by pattern, using the document app from [Concepts](concepts.md). Each pattern is independent, so you can take the ones your application needs.

## Relations and permissions

Keep two kinds of names apart. A **relation** is something you store: who owns a document, who belongs to a team. A **permission** is something you ask about: who can view, who can edit. Application code writes relations and checks permissions.

```zed
definition user {}

definition document {
  relation owner: user
  relation viewer: user

  permission edit = owner
  permission view = viewer + edit
}
```

Checking permissions rather than relations keeps the rules in one place. When editors later become able to view, only the schema changes; every `Licet.check(..., "view", ...)` call stays as it is.

## Ownership

The simplest pattern is a relation and a permission that reads it:

```text
document:1#owner@user:ada
```

`Licet.check(name, "document:1", "edit", "user:ada")` is allowed. Write the owner relationship in the same transaction that creates the record, as shown in [Transactions](transactions.md).

## Groups

Grant a whole group with a userset subject. The relation must list the userset type:

```zed
definition team {
  relation member: user
}

definition document {
  relation viewer: user | team#member
  permission view = viewer
}
```

```text
team:eng#member@user:bob
document:1#viewer@team:eng#member
```

Bob can view document 1 because he's a member of team eng. Adding someone to the team gives them access to every document the team can view, without writing anything on the documents.

Groups can contain groups. `relation member: user | team#member` lets one team include another team's members.

## Hierarchies

Arrows (`->`) follow a relation to another object and ask a permission there. This is how folders pass access to their documents:

```zed
definition folder {
  relation owner: user
  relation viewer: user
  permission view = viewer + owner
}

definition document {
  relation parent: folder
  relation viewer: user
  permission view = viewer + parent->view
}
```

```text
folder:plans#viewer@user:cara
document:roadmap#parent@folder:plans
```

Cara can view the roadmap through its folder. Moving a document is a single write: delete its old `parent` relationship and create the new one.

An arrow can point at the same type, for nested folders:

```zed
definition folder {
  relation parent: folder
  relation viewer: user
  permission view = viewer + parent->view
}
```

`parent->view` is the same as `parent.any(view)`. `parent.all(view)` grants only when every object in `parent` grants `view`, and grants nothing when there are none.

## Public resources

A wildcard subject stands for every object of a type. The relation must allow it:

```zed
definition document {
  relation viewer: user | user:*
  permission view = viewer
}
```

```text
document:1#viewer@user:*
```

Every user can now view document 1, including users created later. Delete the relationship to make it private again.

## Exclusions

`-` removes subjects from a permission. It's the way to model a block list:

```zed
definition document {
  relation viewer: user | user:*
  relation banned: user
  permission view = viewer - banned
}
```

```text
document:1#viewer@user:*
document:1#banned@user:dan
```

Every user can view document 1 except Dan. `Licet.lookup_subjects/5` reports this as `%{subject: "user:*", excluded: ["user:dan"]}`.

## Requiring two conditions

`&` grants only when both sides do. Use it when access needs two independent facts:

```zed
definition organization {
  relation member: user
}

definition document {
  relation org: organization
  relation viewer: user
  permission view = viewer & org->member
}
```

A viewer who has left the organization loses access, even though their `viewer` relationship is still stored.

## Temporary access

Relationships can expire. Declare it once at the top of the schema, and mark the subject types that may carry an expiry:

```zed
use expiration

definition user {}

definition document {
  relation viewer: user | user with expiration
  permission view = viewer
}
```

```text
document:1#viewer@user:guest[expiration:2027-01-01T00:00:00Z]
```

After that moment the relationship no longer counts, and garbage collection eventually removes it.

## Operator precedence

Arrows bind tightest, then `+`, then `&`, then `-`, the same as SpiceDB. Operators of the same kind group to the left:

| Expression | Means |
| --- | --- |
| `a + b & c` | `(a + b) & c` |
| `a - b & c` | `a - (b & c)` |
| `a - b - c` | `(a - b) - c` |

Use parentheses whenever the intent isn't obvious to a reader.

## Keeping checks fast

Each arrow and each userset hop is one more query. A few guidelines:

* Prefer shallow hierarchies. Every check stops with `:depth_exceeded` after `max_depth` hops (50 by default).
* Put the cheapest, most common path first in a union: `viewer + parent->view` can answer from `viewer` without following `parent`.
* A permission may refer to itself through an arrow, such as `view = viewer + parent->view`. A permission that refers to itself directly, such as `view = view`, is rejected when the schema is parsed.

## Checking a model

`mix licet.validate` runs a SpiceDB validation file: a schema, test relationships, and assertions. Write one for your model and run it in CI. See [Testing](testing.md).
