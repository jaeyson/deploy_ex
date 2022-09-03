defmodule DeployEx.ReleaseUploader.UpdateValidator do
  alias DeployEx.ReleaseUploader.UpdateValidator.{MixDepsTreeParser, MixLockFileDiffParser}

  @max_git_diff_concurrency 2

  def reject_unchanged(release_states) do
    with {:ok, file_diffs_by_sha_tuple} <- load_file_diffs(release_states),
         {:ok, dep_changes_by_sha_tuple} <- load_dep_changes(file_diffs_by_sha_tuple),
         {:ok, app_dep_tree} <- MixDepsTreeParser.load_app_dep_tree() do
      {:ok, Enum.filter(release_states, fn release_state ->
        release_has_code_changes?(release_state, file_diffs_by_sha_tuple) or
        release_has_local_dep_changes?(release_state, file_diffs_by_sha_tuple, app_dep_tree) or
        release_has_dep_changes?(release_state, dep_changes_by_sha_tuple, app_dep_tree)
      end)}
    end
  end

  defp load_file_diffs(states) do
    from_to_shas = states |> Enum.map(&{&1.sha, &1.last_sha}) |> Enum.uniq

    with {:ok, file_diffs} <- file_diffs_between(from_to_shas) do
      file_diffs
        |> Enum.reject(fn
          {_sha_tuple, [""]} -> true
          {_sha_tuple, []} -> true
          {_sha_tuple, _} -> false
        end)
        |> Map.new
        |> then(&{:ok, &1})
    end
  end

  defp load_dep_changes(file_diffs_by_sha_tuple) do
    res = file_diffs_by_sha_tuple
      |> filter_file_diffs_for_deps_update
      |> Task.async_stream(
        &MixLockFileDiffParser.git_diff_mix_lock/1,
        max_concurrency: @max_git_diff_concurrency
      )
      |> DeployEx.Utils.reduce_task_status_tuples

    with {:ok, file_diffs_by_sha_tuple} <- res do
      file_diffs_by_sha_tuple
        |> Enum.reject(fn
          {_sha_tuple, [""]} -> true
          {_sha_tuple, []} -> true
          _ -> false
        end)
        |> Map.new
        |> then(&{:ok, &1})
    end
  end

  defp filter_file_diffs_for_deps_update(file_diffs_by_sha_tuple) do
    Enum.filter(file_diffs_by_sha_tuple, fn {_sha_tuple, file_diffs} ->
      Enum.any?(file_diffs, &(&1 =~ "mix.lock"))
    end)
  end

  defp file_diffs_between(from_to_shas) do
    from_to_shas
      |> Task.async_stream(fn {current_sha, last_sha} = sha_tuple ->
        with {:ok, file_diffs} <- git_diff_files_between(current_sha, last_sha) do
          {:ok, {sha_tuple, file_diffs}}
        end
      end, max_concurrency: @max_git_diff_concurrency)
      |> DeployEx.Utils.reduce_task_status_tuples
  end

  defp git_diff_files_between(current_sha, last_sha) do
    case System.shell("git diff --name-only #{current_sha}..#{last_sha}") do
      {output, 0} -> {:ok, output |> String.trim_trailing("\n") |> String.split("\n")}

      {output, code} -> {:error, ErrorMessage.failed_dependency(
        "couldn't run git diff --name-only",
        %{output: output, code: code}
      )}
    end
  end

  defp release_has_code_changes?(%DeployEx.ReleaseUploader.State{
    app_name: app_name,
    sha: current_sha,
    last_sha: last_sha
  }, file_diffs_by_sha_tuple) do
    file_diffs = Map.get(file_diffs_by_sha_tuple, {current_sha, last_sha}) || []

    code_change? = Enum.any?(file_diffs) and Enum.any?(file_diffs, &file_part_of_app(&1, app_name))

    if code_change? do
      IO.puts(to_string(IO.ANSI.format([
        :green, "* #{app_name} has code changes"
      ])))
    end

    code_change?
  end

  defp file_part_of_app(diff, app_name) do
    diff =~ ~r/^apps\/#{app_name}\//
  end

  defp release_has_dep_changes?(%DeployEx.ReleaseUploader.State{
    app_name: app_name,
    sha: current_sha,
    last_sha: last_sha
  }, dep_changes_by_sha_tuple, app_dep_tree) do
    dep_changes = Map.get(dep_changes_by_sha_tuple, {current_sha, last_sha}) || []

    dep_changes? = Enum.any?(app_dep_tree[app_name] || [], fn app_dep_name ->
      Enum.any?(dep_changes, &(&1 === app_dep_name))
    end)

    if dep_changes? do
      IO.puts(to_string(IO.ANSI.format([
        :green, "* #{app_name} has dependency changes"
      ])))
    end

    dep_changes?
  end

  defp release_has_local_dep_changes?(%DeployEx.ReleaseUploader.State{
    app_name: app_name,
    sha: current_sha,
    last_sha: last_sha
  }, file_diffs_by_sha_tuple, app_dep_tree) do
    file_diffs = Map.get(file_diffs_by_sha_tuple, {current_sha, last_sha}) || []
    app_deps = app_dep_tree[app_name]
    changed_apps = Enum.map(file_diffs, &String.replace(&1, ~r/^apps\/([a-z0-9_]+)\/.*/, "\\1"))

    local_dep_changes? = Enum.any?(changed_apps) and Enum.any?(changed_apps, &(&1 in app_deps))

    if local_dep_changes? do
      IO.puts(to_string(IO.ANSI.format([
        :green, "* #{app_name} has local dependency changes"
      ])))
    end

    local_dep_changes?
  end
end
