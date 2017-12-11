defmodule Chronik.Aggregate do
  @moduledoc """
  The `Chronik.Aggregate` is the base for all aggregates in Chronik.

  The module that implements the `Chronik.Aggregate` behaviour
  module can be configured with a number of options:

  * `shutdown_timeout` indicates `Chronik` to shutdown the aggregate
    GenServer after a number of milliseconds. Defualt value is 15
    minutes.

  * `snapshot_every` indicates that a snapshot must be done on the
    `Chronik.Store` every `snapshot_every` domain events
    processed. Default value is 100. This configuration is looked up
    in the `:chronik` app under the given module.

  ## Example

  ```
  defmodule DomainEvents do
    defmodule CounterCreated do
      defstruct [:id]
    end

    defmodule CounterIncremented do
      defstruct [:id, :increment]
    end
  end

  defmodule Counter do
    @behaviour Chronik.Aggregate

    alias Chronik.Aggregate
    alias DomainEvents.CounterCreated
    alias DomainEvents.CounterIncremented

    defstruct [:id, value: 0]

    # Public API

    def create(id), do: Aggregate.command(__MODULE__, id, {:create, id})

    def increment(id, increment),
      do: Aggregate.command(__MODULE__, id, {:increment, increment})

    # Command handlers

    def handle_command({:create, id}, nil) do
      %CounterCreated{id: id}
    end
    def handle_command({:create, _id}, _state) do
      raise "counter alredy created"
    end
    def handle_command({:increment, increment}, %Counter{id: id}) do
      %CounterIncremented{id: id, increment: increment}
    end

    # Event handlers

    def handle_event(%CounterCreated{id: id}, nil) do
      %Counter{id: id}
    end
    def handle_event(%CounterIncremented{increment: i}, %Counter{} = state) do
      update_in(state.value, &(&1 + i))
    end
  end
  ```

  The application code must implement the `handle_command` and `handle_event`
  callbacks.
  """

  @typedoc """
  The `state` represents the state of an aggregate.

  Is used in the to validate a command (in `handle_command`) and
  in `handle_event` callback.
  """
  @type state :: term()

  @doc """
  The `handle_command` is the entry point for commands on an aggregate.

  The command format is application dependend. Throughout `Chronik`,
  commands are tagged tuples where the first element is an atom
  indicating the command to execute and the remaining elements are arguments
  to the command. E.g: `{:add_item, 13, "Elixir Book", "$15.00"}`

  ## Example

  ```
  def handle_command({:add_item, id, book, price}, %Cart{}) do
    %ItemsAdded{id: id, book: book, price: price}
  end
  ```

  This `handle_command` validate the command. If the command is valid on the
  given state, the function should return a list (or a single) of domain events.
  If the command is invalid the `handle_command` should raise an exception.
  """
  @callback handle_command(cmd :: Chronik.command(),
                         state :: state()) :: [Chronik.domain_event()] | no_return()

  @doc """
  The `handle_event` is the transition function for the aggregate. After
  command validation, the aggregate generates a number of domain events
  and then the aggregate state is updated for each event with this function.

  Note that this function can not fail since the domain event where
  generated by a valid command.
  """
  @callback handle_event(event :: Chronik.domain_event(), state :: state()) :: state()

  @typedoc "An aggregate is identified by its module and an id."
  @type t :: {module(), Chronik.id()}

  # Aggregate

  use GenServer

  require Logger

  alias Chronik.Aggregate.Supervisor
  alias Chronik.{AggregateRegistry, Config}

  defstruct [:id,
             :num_events,
             :blocks,
             :store,
             :pub_sub ,
             :module,
             :aggregate_version,
             :aggregate_state,
             :timer]

  # API

  @doc """
  The `command` function is the entry point to Chronik aggregate.
  It sends the `cmd` request to the Aggregate identifed by `module` and `id`.
  The `timeout` is either `:infinity` or a number of milliseconds (defaults
  to `5000`).

  The results is either `:ok` or `{:error, reason}` in case of failure.
  """
  @spec command(module :: module(),
                    id :: Chronik.id(),
                   cmd :: term(),
               timeout :: :infinity | non_neg_integer()) :: :ok | {:error, String.t}
  def command(module, id, cmd, timeout \\ 5000) do
    log(id, "executing command #{inspect cmd}")
    case Registry.lookup(AggregateRegistry, {module, id}) do
      [] ->
        case Supervisor.start_aggregate(module, id) do
          {:ok, pid} ->
            GenServer.call(pid, {module, cmd}, timeout)
          {:error, reason} ->
            {:error, "cannot create process for aggregate root " <>
                     "{#{module}, #{id}}: #{inspect reason}"}
        end
      [{pid, _metadata}] -> GenServer.call(pid, {module, cmd}, timeout)
    end
  end

  @doc """
  The `state(module, id)` function returns the current aggregate state.

  This should only be used for debugging purposes.
  """
  @spec state(module(), Chronik.id()) :: Chronik.Aggregate.state()
  def state(module, id), do: GenServer.call(via(module, id), :state)

  @doc """
  Start a `Chronik.Aggregate` with callbacks on `module` with id `id`.
  """
  @spec start_link(module :: module(),
                       id :: Chronik.id()) :: {:ok, pid()}
                                            | {:error, reason :: String.t}
  def start_link(module, id) do
    GenServer.start_link(__MODULE__, {module, id}, name: via(module, id))
  end

  # GenServer Callbacks

  def init({module, id}) do
    # Fetch the configuration for the Store and the PubSub.
    {store, pub_sub} = Config.fetch_adapters()
    log(id, "starting aggregate.")
    {:ok, version, aggregate_state} = load_from_store(module, id, store)

    {:ok, %__MODULE__{id: id,
            aggregate_state: aggregate_state,
            aggregate_version: version,
            timer: update_timer(nil, module),
            num_events: 0,
            blocks: 0,
            store: store,
            pub_sub: pub_sub,
            module: module}}
  end

  # The :state returns the current aggregate state.
  def handle_call(:state, _from, %__MODULE__{aggregate_state: as} = state) do
    {:reply, as, state}
  end
  # When called with a function, the aggregate executes the function in
  # the current state and if no exceptions were raised, it stores and
  # publishes the events to the PubSub.
  def handle_call({module, cmd}, _from, %__MODULE__{aggregate_state: as} = state) do
    new_events =
      cmd
      |> module.handle_command(as)
      |> List.wrap()

    log(state.id, "newly created events: #{inspect new_events}")
    new_state = Enum.reduce(new_events, as, &module.handle_event/2)
    store_and_publish(new_events, new_state, state)
  rescue
    e ->
      if state do
        {:reply, {:error, e}, state}
      else
        {:stop, :normal, {:error, e}, state}
      end
  end

  @doc false
  # The shutdown timeout is implemented by auto-sending a message
  # :shutdown to the current process.
  def handle_info(:shutdown, %__MODULE__{id: id} = state) do
    # TODO: Do a snapshot before going down.
    log(id, "aggregate going down gracefully due to inactivity.")
    {:stop, :normal, state}
  end

  # Internal functions

  defp via(module, id) do
    {:via, Registry, {AggregateRegistry, {module, id}}}
  end

  # Loads the aggregate state from the domain event store.  It returns
  # the state on success or nil if there is no recorded domain events
  # for the aggregate.
  defp load_from_store(module, id, store) do
    aggregate_tuple = {module, id}
    {version, state} =
      case store.get_snapshot(aggregate_tuple) do
        nil ->
          log(id, "no snapshot found on the store.")
          {:all, nil}
        {version, _state} = snapshot ->
          log(id, "found a snapshot on the store with version " <>
                  "#{inspect version}")
          snapshot
      end
    case store.fetch_by_aggregate(aggregate_tuple, version) do
      {:error, _} -> state
      {:ok, version, records} ->
        log(id, "replaying events up to version: #{inspect version}.")
        new_state =
          records
          |> Enum.map(&Map.get(&1, :domain_event))
          |> apply_events(state, module)
        {:ok, version, new_state}
    end
  end

  defp apply_events(events, state, module) do
    Enum.reduce(events, state, &module.handle_event/2)
  end

  defp store_and_publish(events, new_state,
    %__MODULE__{id: id,
      num_events: num_events,
      blocks: blocks,
      store: store,
      pub_sub: pub_sub,
      module: module,
      aggregate_version: aggregate_version} = state) do

    # Compute the expected version to be found on the Store.
    version =
      case aggregate_version do
        :empty -> :no_stream
        v -> v
      end

    log(id, "writing events to the store: #{inspect events}")

    {new_version, records} =
      case store.append({module, id}, events, [version: version]) do
        {:ok, v, s} -> {v, s}
        {:error, _} ->
          raise "a newer version of the aggregate found on the store"
      end

    log(id, "broadcasting records: #{inspect records}")
    pub_sub.broadcast(records)

    num_events = num_events + length(events)
    blocks =
      if div(num_events, get_snapshot_every(module)) > blocks do
        log(id, "saving a snapshot with version #{inspect new_version}")
        store.snapshot({module, id}, new_state, new_version)
        div(num_events, get_snapshot_every(module))
      else
        blocks
      end

    {:reply, :ok,
      %__MODULE__{state |
        aggregate_state: new_state,
        aggregate_version: new_version,
        timer: update_timer(state.timer, module),
        num_events: num_events,
        blocks: blocks
      }}
  end

  defp log(id, msg) do
    Logger.debug(fn -> "[#{inspect __MODULE__}:#{inspect id}] #{msg}" end)
  end

  defp update_timer(timer, module) do
    shutdown_timeout = get_shutdown_timeout(module)

    if timer do
      Process.cancel_timer(timer)
      receive do
        :shutdown -> :ok
      after
        0 -> :ok
      end
    end

    if shutdown_timeout != :infinity,
      do: Process.send_after(self(), :shutdown, shutdown_timeout)
  end

  defp get_shutdown_timeout(module),
    do: Config.get_config(module, :shutdown_timeout, 15 * 1000 * 60)

  defp get_snapshot_every(module),
    do: Config.get_config(module, :snapshot_every, 100)
end
