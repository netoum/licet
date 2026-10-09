# Concepts

Licet decides access from facts about how things relate to each other, instead of from roles attached to users. This page introduces the vocabulary used throughout the documentation, with one example that the other guides reuse.

## The example

A small document app has users, teams, folders, and documents. Ada owns the "plans" folder. The "roadmap" document lives in that folder. Bob is a member of the engineering team, and the engineering team may view the roadmap.

The questions the app asks are: can Ada edit the roadmap? Can Bob view it? Which documents can Bob view?

## Objects

An **object** is anything you want to protect or grant access to, written `type:id`:

* `user:ada`
* `team:eng`
* `folder:plans`
* `document:roadmap`

The type comes from your schema. The id is your own identifier, usually a primary key. Licet doesn't need a copy of the row itself, only its id.

## Relationships

A **relationship** (also called a tuple) is one stored fact. It links a **resource** to a **subject** through a **relation**:

```text
document:roadmap#parent@folder:plans
└─ resource ───┘ └rel─┘ └ subject ─┘
```

Read it as "folder plans is the parent of document roadmap". The example app stores these relationships:

```text
folder:plans#owner@user:ada
document:roadmap#parent@folder:plans
team:eng#member@user:bob
document:roadmap#viewer@team:eng#member
```

The last one has a **userset** as its subject: `team:eng#member` means "every member of team eng". Usersets let one relationship grant access to a whole group, and the group can change without touching the document.

A subject can also be a **wildcard**, such as `user:*`, meaning every user. It's how you model public resources.

Relationships are written with `Licet.write/3` and removed with `Licet.write/3` or `Licet.delete/3`. Licet keeps a history of them for a configurable window, so a check can be answered as of an earlier moment. See [Consistency](consistency.md).

## The schema

The **schema** says which relations exist, which subjects each relation accepts, and how permissions are computed. It's written in SpiceDB's schema language:

```zed
definition user {}

definition team {
  relation member: user
}

definition folder {
  relation owner: user
  relation viewer: user | team#member

  permission edit = owner
  permission view = viewer + edit
}

definition document {
  relation parent: folder
  relation owner: user
  relation viewer: user | user:* | team#member

  permission edit = owner + parent->edit
  permission view = viewer + edit + parent->view
}
```

Each `definition` is an object type.

A **relation** is stored data. `relation viewer: user | user:* | team#member` accepts a single user, the wildcard for every user, or the members of a team.

A **permission** is computed and never stored. It combines relations and other permissions:

* `+` is a union: either side grants.
* `&` is an intersection: both sides must grant.
* `-` is an exclusion: the left side grants unless the right side does.
* `->` follows a relation to other objects and asks a permission there. `parent->edit` means "anyone who can edit the parent folder".

[Modeling permissions](modeling.md) shows common patterns, and [Schema language](zed.md) is the full reference.

## Checks and lookups

A **check** asks whether a subject has a permission on a resource:

```elixir
Licet.check(MyApp.Licet, "document:roadmap", "edit", "user:ada")
#=> {:ok, :allowed}
```

Ada can edit the roadmap because she owns its parent folder: `edit = owner + parent->edit` follows `parent` to `folder:plans`, where `edit = owner` holds.

```elixir
Licet.check(MyApp.Licet, "document:roadmap", "view", "user:bob")
#=> {:ok, :allowed}
```

Bob can view it through the userset: the roadmap's viewers include `team:eng#member`, and Bob is a member.

A **lookup** runs the question in one of two directions:

```elixir
Licet.lookup_resources(MyApp.Licet, "document", "view", "user:bob")
#=> {:ok, ["roadmap"], nil}

Licet.lookup_subjects(MyApp.Licet, "document:roadmap", "view", "user")
#=> {:ok, [%{subject: "user:ada", excluded: []}, %{subject: "user:bob", excluded: []}], nil}
```

`lookup_resources/5` lists what a subject can access when the candidate set is the permission graph. For a SQL-backed list page, page the table first and filter with `check_bulk/3`; see [Phoenix](phoenix.md). `lookup_subjects/5` lists who has access, which is how you build a sharing dialog.

## Consistency tokens

Every write returns a **token** that names the database transaction it committed in. A check that receives the token is guaranteed to see that write. Without one, a check reads a recent snapshot that the whole instance shares and caches. [Consistency](consistency.md) explains when each choice is right.

## An instance

An **instance** is one running Licet, started in your supervision tree with a `name`, a `repo`, and a table `prefix`. Every function takes the instance name as its first argument. Most applications run exactly one.
