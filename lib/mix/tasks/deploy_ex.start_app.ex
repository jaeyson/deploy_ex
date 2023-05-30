defmodule Mix.Tasks.DeployEx.StartApp do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Starts the systemd service for a specific service"
  @moduledoc """
  Starts the systemd service for a specific service, partial completions are allowed

  ## Example
  ```bash
  $ mix deploy_ex.start_app my_app
  ```
  """

  def run(args) do
    :ssh.start()

    {opts, node_name_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with {:ok, app_name} <- DeployExHelpers.find_app_name(node_name_args),
         _ = Mix.shell().info([:yellow, "Starting #{app_name} systemd service"]),
         :ok <- start_service(app_name, opts) do
      Mix.shell().info([:green, "Started #{app_name} systemd service successfully"])
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp start_service(app_name, opts) do
    DeployExHelpers.run_ssh_command(
      opts[:directory],
      app_name,
      DeployEx.SystemDController.start_service(app_name)
    )
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean
      ]
    )
  end
end
