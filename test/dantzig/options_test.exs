defmodule Dantzig.OptionsTest do
  use ExUnit.Case, async: true

  alias Dantzig.HiGHS

  describe "build_options_content/1" do
    test "emits existing options when set" do
      content = HiGHS.build_options_content(mip_rel_gap: 0.001, log_to_console: true)

      assert content =~ "mip_rel_gap = 0.001"
      assert content =~ "log_to_console = true"
    end

    test "emits mip_heuristic_effort" do
      content = HiGHS.build_options_content(mip_heuristic_effort: 0.5)
      assert content =~ "mip_heuristic_effort = 0.5"
    end

    test "emits mip_max_start_nodes" do
      content = HiGHS.build_options_content(mip_max_start_nodes: 50)
      assert content =~ "mip_max_start_nodes = 50"
    end

    test "emits parallel" do
      content = HiGHS.build_options_content(parallel: "on")
      assert content =~ "parallel = on"
    end

    test "emits threads" do
      content = HiGHS.build_options_content(threads: 4)
      assert content =~ "threads = 4"
    end

    test "emits random_seed" do
      content = HiGHS.build_options_content(random_seed: 42)
      assert content =~ "random_seed = 42"
    end

    test "emits all new options together" do
      content =
        HiGHS.build_options_content(
          mip_rel_gap: 0.01,
          mip_heuristic_effort: 0.2,
          mip_max_start_nodes: 100,
          parallel: "choose",
          threads: 2,
          random_seed: 7
        )

      assert content =~ "mip_rel_gap = 0.01"
      assert content =~ "mip_heuristic_effort = 0.2"
      assert content =~ "mip_max_start_nodes = 100"
      assert content =~ "parallel = choose"
      assert content =~ "threads = 2"
      assert content =~ "random_seed = 7"
    end

    test "omits unset options" do
      content = HiGHS.build_options_content(mip_rel_gap: 0.001)

      refute content =~ "mip_heuristic_effort"
      refute content =~ "parallel"
      refute content =~ "threads"
      refute content =~ "random_seed"
      refute content =~ "mip_max_start_nodes"
      refute content =~ "log_to_console"
      refute content =~ "mip_max_stall_nodes"
    end

    test "omits nil-valued options" do
      content =
        HiGHS.build_options_content(
          mip_rel_gap: 0.001,
          mip_heuristic_effort: nil,
          random_seed: nil
        )

      assert content =~ "mip_rel_gap = 0.001"
      refute content =~ "mip_heuristic_effort"
      refute content =~ "random_seed"
    end

    test "returns empty string when no options set" do
      assert HiGHS.build_options_content([]) == ""
    end

    test "ignores unknown keys (not in whitelist)" do
      content =
        HiGHS.build_options_content(
          mip_rel_gap: 0.001,
          some_unknown_option: "value"
        )

      assert content =~ "mip_rel_gap = 0.001"
      refute content =~ "some_unknown_option"
    end
  end
end
