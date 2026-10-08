Application.ensure_all_started(:postgrex)
{:ok, _} = Licet.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Licet.TestRepo, :manual)
ExUnit.start(exclude: [:spicedb])
