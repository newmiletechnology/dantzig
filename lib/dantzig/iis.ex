defmodule Dantzig.IIS do
  @moduledoc """
  Irreducible Infeasible Set - the minimal set of constraints
  and variable bounds that together cause infeasibility.

  When a linear program is infeasible, the IIS identifies which
  constraints conflict, helping diagnose and fix the problem.
  """

  @type t :: %__MODULE__{
          constraints: [String.t()],
          variables: [String.t()],
          raw_content: String.t()
        }

  defstruct constraints: [],
            variables: [],
            raw_content: ""

  @doc """
  Parses an IIS model file in LP format into an IIS struct.

  Extracts constraint names (lines with `:` in the `st` section)
  and variable names (from the `bounds` section).
  """
  @spec parse(String.t()) :: t()
  def parse(contents) do
    {constraints, variables} =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], []}, &classify_line/2)

    %__MODULE__{
      constraints: constraints |> Enum.reverse() |> Enum.uniq(),
      variables: variables |> Enum.reverse() |> Enum.uniq(),
      raw_content: contents
    }
  end

  @doc """
  Reads and parses an IIS model file from disk.

  Returns `nil` if the file doesn't exist or is empty.
  """
  @spec from_file(String.t() | nil) :: t() | nil
  def from_file(nil), do: nil

  def from_file(path) do
    case File.read(path) do
      {:ok, contents} when byte_size(contents) > 0 -> parse(contents)
      _ -> nil
    end
  end

  defp classify_line(line, {cs, vs}) do
    trimmed = String.trim(line)

    cond do
      # Constraint lines have a colon (e.g. "c0: 1 x0 + 1 x1 >= 20")
      # Skip LP comments which start with \
      String.contains?(trimmed, ":") && !String.starts_with?(trimmed, "\\") ->
        [name | _] = String.split(trimmed, ":", parts: 2)
        {[String.trim(name) | cs], vs}

      # Variable bounds: "0 <= x0", "x0 <= 5", or "x0 free"
      # Variable names start with a letter, so exclude pure numbers
      match = Regex.run(~r/^([a-zA-Z]\w*)\s+free$/, trimmed) ->
        {cs, [Enum.at(match, 1) | vs]}

      match = Regex.run(~r/<=\s*([a-zA-Z]\w*)/, trimmed) ->
        {cs, [Enum.at(match, 1) | vs]}

      match = Regex.run(~r/^([a-zA-Z]\w*)\s*<=/, trimmed) ->
        {cs, [Enum.at(match, 1) | vs]}

      true ->
        {cs, vs}
    end
  end
end
