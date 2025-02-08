defmodule Mix.Tasks.DeployEx.DownloadFile do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Downloads a file from a remote server"
  @moduledoc """
  Downloads a file from a remote server using SCP

  ## Example
  ```bash
  $ mix deploy_ex.download_file my_app /path/to/remote/file /path/to/local/file
  ```

  ## Options
  - `directory` - Terraform directory path (default: #{@terraform_default_path})
  - `force` - Force overwrite existing files
  - `quiet` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, node_name_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, [app_name, remote_path, local_path]} <- parse_node_name_args(node_name_args),
         {:ok, app_name} <- DeployExHelpers.find_app_name([app_name]),
         _ = Mix.shell().info([:yellow, "Downloading #{remote_path} from #{app_name}"]),
         :ok <- download_file(app_name, remote_path, local_path, opts) do
      Mix.shell().info([:green, "Downloaded #{remote_path} to #{local_path} successfully"])
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_node_name_args(args) do
    case args do
      [app_name, remote_path | rest] ->
        {:ok, [app_name, remote_path, List.first(rest) || Path.basename(remote_path)]}

      _ ->
        {:error, "Expected arguments: <app_name> <remote_path> [local_path]"}
    end
  end

  defp download_file(app_name, remote_path, local_path, opts) do
    if File.exists?(local_path) and not !!opts[:force] do
      {:error, "File #{local_path} already exists. Use --force to overwrite."}
    else
      with {:ok, instance_ips} <- DeployExHelpers.find_aws_instance_ips(app_name),
           {:ok, pem_file} <- DeployExHelpers.find_pem_file(opts[:directory]) do

        # Get first IP if multiple returned
        ip = List.first(instance_ips)

        # Convert paths to absolute paths
        abs_pem_file = Path.expand(pem_file)
        abs_local_path = Path.expand(local_path)

        # Build scp command
        scp_cmd = "scp -i #{abs_pem_file} admin@#{ip}:#{remote_path} #{abs_local_path}"

        # Run from current directory instead of terraform directory
        DeployExHelpers.run_command(scp_cmd, File.cwd!())
      end
    end
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
