# Modeling

A definition is a type of object. A relation is a set of subjects stored as tuples. A permission is computed from relations and other permissions.

```zed
definition user {}

definition team {
  relation member: user
}

definition document {
  relation owner: user
  relation viewer: user | user:* | team#member
  relation parent: document
  permission view = owner + viewer + parent->view
}
```

`document:1#viewer@user:ada` says ada is a viewer of document 1. `document:1#viewer@team:eng#member` says members of team eng are viewers. `document:1#viewer@user:*` says every user is a viewer.

`parent->view` walks the `parent` relation and checks `view` on each parent. Wildcards and userset tuples are not used as arrow targets. A userset is expanded by walking the referenced relation instead.

`edit & viewer` requires both. `view - viewer` allows `view` and then removes `viewer`. `+` is evaluated before `&` and `-`, and `&` and `-` associate to the left, so `a + b & c` is `(a + b) & c`.

Keep the graph shallow. Each arrow or userset hop counts toward the depth limit (default 50). A permission that refers to itself through an arrow, such as `view = parent->view`, is allowed. A permission that refers to itself directly, such as `view = view`, is rejected.
