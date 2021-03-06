defmodule Chronik.Aggregate.Supervisor do
  @moduledoc false

  use Supervisor, start: {__MODULE__, :start_link, []}

  @name __MODULE__

  # API

  @spec start_aggregate(aggregate :: atom(), id :: term()) ::
          {:ok, pid()}
          | {:error, term()}
  def start_aggregate(aggregate, id) do
    Supervisor.start_child(__MODULE__, [aggregate, id])
  end

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: @name)
  end

  # Supervisor callbacks

  def init([]) do
    child = worker(Chronik.Aggregate, [], restart: :transient)
    supervise([child], strategy: :simple_one_for_one)
  end
end
