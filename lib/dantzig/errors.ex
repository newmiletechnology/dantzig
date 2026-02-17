defmodule Dantzig.InfeasibleError do
  @moduledoc """
  Raised when a problem is infeasible (no solution exists that satisfies all constraints).
  """

  defexception [:message, :iis]

  @impl true
  def exception(opts) do
    iis = Keyword.get(opts, :iis)

    message =
      if iis && length(iis.constraints) > 0 do
        constraint_list = Enum.join(iis.constraints, ", ")

        """
        Problem is infeasible.

        Irreducible Infeasible Set (IIS):
          Constraints: #{constraint_list}
          Variables: #{Enum.join(iis.variables, ", ")}
        """
      else
        "Problem is infeasible. IIS not available (use compute_iis: true option)."
      end

    %__MODULE__{message: message, iis: iis}
  end
end

defmodule Dantzig.UnboundedError do
  @moduledoc """
  Raised when a problem is unbounded (objective can be improved infinitely).
  """

  defexception message: "Problem is unbounded - objective can be improved infinitely."
end

defmodule Dantzig.SolverError do
  @moduledoc """
  Raised when the HiGHS solver encounters an error during execution.
  """

  defexception [:message, :reason, :details]

  @impl true
  def exception(opts) do
    reason = Keyword.get(opts, :reason)
    details = Keyword.get(opts, :details, %{})

    message = """
    HiGHS solver error: #{reason}

    Details: #{inspect(details)}
    """

    %__MODULE__{message: message, reason: reason, details: details}
  end
end
