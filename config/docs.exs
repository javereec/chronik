use Mix.Config

config :chronik, :adapters,
  pub_sub: Chronik.PubSub.Adapters.Registry,
  store: Chronik.Store.Adapters.ETS

config :chronik, Chronik.Store.Adapters.Ecto.Repo,
  adapter: Ecto.Adapters.MySQL