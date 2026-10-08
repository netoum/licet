schema = """
definition user {}
definition document {
  relation owner: user
  permission view = owner
}
"""

{:ok, compiled} = Licet.Schema.parse(schema)
{:ok, rel} = Licet.Relationship.parse("document:1#owner@user:ada")
reader = %Licet.Reader.Memory{tuples: [rel]}
revision = %{snapshot: "1:1:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}
resource = %{type: "document", id: "1", relation: ""}
subject = %{type: "user", id: "ada", relation: ""}

Benchee.run(
  %{
    "check owner" => fn ->
      {:ok, :allowed} =
        Licet.Engine.check(compiled, reader, revision, resource, "view", subject, [])
    end
  },
  time: 1,
  memory_time: 0
)
