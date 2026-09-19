defmodule OpsBrain.Correlation do
  @moduledoc "Evidence-linked candidates, never causal proof. Explicit company/environment/target identity required."
  def evaluate(symptom, changes, topology, now) do
    known = Enum.filter(changes, &(&1.received_at <= now))

    candidates =
      for c <- known,
          c.company_id == symptom.company_id,
          c.environment_id == symptom.environment_id,
          c.target_id == symptom.target_id or {c.target_id, symptom.target_id} in topology,
          abs(c.occurred_at - symptom.occurred_at) <= 3600 do
        %{
          change_evidence_id: c.evidence_id,
          symptom_evidence_id: symptom.evidence_id,
          relation: "investigation candidate, not established cause",
          counterevidence:
            if(c.occurred_at > symptom.occurred_at, do: ["symptom predates change"], else: []),
          elapsed_seconds: symptom.occurred_at - c.occurred_at
        }
      end

    %{
      version: 1,
      candidates: Enum.sort_by(candidates, & &1.change_evidence_id),
      missing: "Comparable healthy measurements and mechanism evidence required",
      alternatives_preserved: true
    }
  end
end
