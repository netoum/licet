defmodule Licet.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :licet, adapter: Ecto.Adapters.Postgres
end
