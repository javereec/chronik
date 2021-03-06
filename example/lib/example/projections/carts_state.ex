defmodule Example.Projection.CartsState do
  @moduledoc "This projection keeps the cart state by adding and removing
  items to it."
  @behaviour Chronik.Projection
  alias Chronik.Projection

  alias Example.DomainEvents.{CartCreated, ItemsAdded, ItemsRemoved}
  alias Chronik.EventRecord

  # # The initial state is nil.
  def init(_opts), do: {nil, []}

  # From the initial state we can only create the cart
  # Initially the cart is empty (no items of any type)
  def handle_event(%EventRecord{domain_event: %CartCreated{id: id}}, nil) do
    %{id => %{}}
  end
  def handle_event(%EventRecord{domain_event: %CartCreated{id: id}}, carts) do
    Map.put(carts, id, %{})
  end
  # Removing a number of items only decrements that item quantity
  def handle_event(%EventRecord{domain_event: %ItemsRemoved{id: id,
    item_id: item_id, quantity: quantity}}, carts) do

    current_quantity = (carts[id][item_id] || 0)
    %{carts | id => Map.put(carts[id], item_id, current_quantity - quantity)}
  end

  # Adding a number of items only increments that item quantity
  def handle_event(%EventRecord{domain_event: %ItemsAdded{id: id,
    item_id: item_id, quantity: quantity}}, carts) do

    current_quantity = (carts[id][item_id] || 0)
    %{carts | id => Map.put(carts[id], item_id, current_quantity + quantity)}
  end

  def child_spec(opts) do
    %{
    id: __MODULE__,
    start: {Projection, :start_link, [__MODULE__, opts]},
    type: :supervisor
    }
  end

  defoverridable child_spec: 1
end
