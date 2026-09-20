defmodule OpsBrain.Kubernetes do
  @moduledoc "Kubernetes compatibility facade over the single maintained Workloads list/watch engine."

  def reconcile(c, now, fence \\ nil),
    do: OpsBrain.WorkloadCollection.reconcile(Map.put_new(c, :resources, ["pods"]), now, fence)

  @doc "Pure Pod list compatibility entry point using the maintained decoder."
  def initial(data, namespace, gap),
    do: OpsBrain.Workloads.list_page(OpsBrain.Workloads.empty("pods", namespace, gap), data, 200)

  def decode_watch(state, body), do: OpsBrain.Workloads.watch(state, body, 200)
end
