defmodule Guards do
  @moduledoc false

  @doc """
  Determines whether or not a value is blank (nil or empty string)
  """
  defguard is_blank?(value) when value in [nil, ""]

  @doc """
  Determines whether or not a value is present (not nil and not empty)
  """
  defguard is_present?(value) when value not in [nil, ""]
end
