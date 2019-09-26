defmodule Staxx.ExChain do
  @moduledoc """
  Default module for controlling different EVM's
  """

  alias Staxx.ExChain.EVM
  alias Staxx.ExChain.EVM.Implementation.{Geth, GethVDB, Ganache}
  alias Staxx.ExChain.EVM.{Account, Config, Process}
  alias Staxx.ExChain.EVM.Supervisor, as: EvmSupervisor
  alias Staxx.ExChain.EVM.Registry, as: EvmRegistry
  alias Staxx.ExChain.SnapshotManager
  alias Staxx.ExChain.Snapshot.Details
  alias Staxx.Storage

  require Logger

  @data_file_name "evm_data.bin"

  @typedoc """
  Chain EVM type.

  Available types are:
   - `:ganache` -  Ganache blockchain
   - `:geth` - Geth evm
   - `:geth_vdb` - Special geth evm version from https://github.com/vulcanize/go-ethereum
   - `:parity` - Parity evm
  """
  @type evm_type :: :ganache | :geth | :geth_vdb | :parity

  @typedoc """
  Big random number generated by `Chain.unique_id/0` that identifiers new chain id
  """
  @type evm_id :: binary()

  @doc """
  Start a new EVM using given configuration
  It will generate unique ID for new evm process
  """
  @spec start(Config.t()) :: {:ok, evm_id()} | {:error, term()}
  def start(%Config{type: :geth} = config), do: start_evm(Geth, config)

  def start(%Config{type: :geth_vdb} = config), do: start_evm(GethVDB, config)

  def start(%Config{type: :ganache} = config), do: start_evm(Ganache, config)

  def start(%Config{type: _}), do: {:error, :unsuported_evm_type}

  # Ability to start chain using map
  def start(config) when is_map(config) do
    Config
    |> Kernel.struct(config)
    |> start()
  end

  @doc """
  Try starting existing stored chain.

  Note: `http_port`, `ws_port` and `notification_pid` will be overwriten !
  """
  @spec start_existing(evm_id(), nil | pid()) :: {:ok, evm_id()} | {:error, term()}
  def start_existing(id, notify_pid \\ nil) do
    with {:pid, nil} <- {:pid, get_pid(id)},
         {:details, %{db_path: db_path} = details} <- {:details, Storage.get(id)},
         {:path, true} <- {:path, File.dir?(db_path)} do
      config =
        details
        |> Map.drop([:status, :http_port, :ws_port])
        |> Map.put(:notify_pid, notify_pid)

      Logger.debug("#{id} starting existing chain from storage with config #{inspect(config)}")

      Config
      |> Kernel.struct(config)
      |> start()
    else
      {:pid, _pid} ->
        {:error, "chain #{id} is already alive !"}

      {:details, _details} ->
        {:error, "no configuration exist in storage for chain id #{id}"}

      {:path, _exist} ->
        {:error, "no folder with chain data exist for chain id #{id}"}
    end
  end

  @doc """
  Stop started EVM instance
  """
  @spec stop(evm_id()) :: :ok
  def stop(id) do
    case get_pid() do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, :stop)
    end
  end

  @doc """
  Check if chain with given id exist
  """
  @spec exists?(evm_id()) :: boolean()
  def exists?(id) do
    pid = get_pid(id)
    res = Storage.get(id)

    pid != nil || res != nil
  end

  @doc """
  Check if chain with given id exist and alive
  """
  @spec alive?(evm_id()) :: boolean()
  def alive?(id), do: nil != get_pid(id)

  @doc """
  Load details for running chain.
  """
  @spec details(evm_id()) :: {:ok, Process.t()} | {:error, term()}
  def details(id), do: GenServer.call(get_pid(id), :details)

  @doc """
  Get running chain configuration
  """
  @spec get_config(evm_id()) :: {:ok, Config.t()} | {:error, term()}
  def get_config(id), do: GenServer.call(get_pid(id), :config)

  @doc """
  Set new `notify_pid` for exising chain
  """
  @spec new_notify_pid(evm_id(), pid()) :: :ok
  def new_notify_pid(id, pid), do: GenServer.cast(get_pid(id), {:new_notify_pid, pid})

  @doc """
  Clean everything related to this chain.
  If chain is running - it might cause some issues.
  Please validate before removing.
  """
  @spec clean(evm_id()) :: :ok | {:error, term()}
  def clean(id) do
    with nil <- get_pid(id),
         %{id: ^id, db_path: path} <- Storage.get(id),
         :ok <- EVM.clean(id, path),
         :ok <- Storage.remove(id) do
      :ok
    else
      _ ->
        {:error, "#{id} error removing chain details"}
    end
  end

  @doc """
  Locks chain and decline any operations on chain
  """
  @spec lock(evm_id()) :: :ok | {:error, term()}
  def lock(id), do: GenServer.cast(get_pid(id), :lock)

  @doc """
  Unlocks chain and allow any operations on chain
  """
  @spec unlock(evm_id()) :: :ok | {:error, term()}
  def unlock(id), do: GenServer.cast(get_pid(id), :unlock)

  @doc """
  Generates new chain snapshot and places it into given path
  If path does not exist - system will try to create this path

  **Note** this spanshot will be taken based on chain files.
  For chains with internal shnapshot features - you might use `Chain.take_internal_snapshot/1`

  Function will return `:ok` and will notify system after snapshot will be made
  """
  @spec take_snapshot(evm_id(), binary) :: :ok | {:error, term()}
  def take_snapshot(id, description \\ ""),
    do: GenServer.cast(get_pid!(id), {:take_snapshot, description})

  @doc """
  Revert previously generated snapshot.
  For `ganache` chain you could provide `id` for others - path to snapshot
  """
  @spec revert_snapshot(evm_id(), Staxx.ExChain.Snapshot.Details.t()) :: :ok | {:error, term()}
  def revert_snapshot(id, %Staxx.ExChain.Snapshot.Details{} = snapshot) do
    case Staxx.ExChain.SnapshotManager.exists?(snapshot) do
      false ->
        {:error, "Snapshot not exist"}

      true ->
        GenServer.cast(get_pid!(id), {:revert_snapshot, snapshot})
    end
  end

  def revert_snapshot(_id, _), do: {:error, "Wrong snapshot details"}

  @doc """
  Load list of initial accounts for chain
  """
  @spec initial_accounts(evm_id()) :: {:ok, [Account.t()]} | {:error, term()}
  def initial_accounts(id), do: GenServer.call(get_pid!(id), :initial_accounts)

  @doc """
  Load list of all active (running) chains from system
  """
  @spec list() :: [map()]
  def list() do
    EvmSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.map(&Registry.keys(EvmRegistry, &1))
    |> List.flatten()
    |> Enum.map(fn id ->
      case get_config(id) do
        {:ok, config} ->
          config
          |> Map.drop([:notify_pid])

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Storage.list())
    |> Enum.uniq_by(fn %{id: id} -> id end)
  end

  @doc """
  Generate uniq ID

  It also checks if such ID exist in runing processes list
  and checks if chain db exist for this `id`
  """
  @spec unique_id() :: evm_id()
  def unique_id() do
    <<new_unique_id::big-integer-size(8)-unit(8)>> = :crypto.strong_rand_bytes(8)
    new_unique_id = to_string(new_unique_id)

    with nil <- get_pid(new_unique_id),
         nil <- Storage.get(new_unique_id),
         false <- File.exists?(evm_db_path(new_unique_id)) do
      new_unique_id
    else
      _ ->
        unique_id()
    end
  end

  @doc """
  Write any additional information to `evm_data.json` file into chain DB path.
  Thi sfile will be used any any other processes for storage info in there.
  """
  @spec write_external_data(evm_id(), term) :: :ok | {:error, term}
  def write_external_data(_id, nil), do: :ok

  def write_external_data(id, data) do
    path = evm_db_path(id)

    with true <- File.exists?(path),
         encoded <- :erlang.term_to_binary(data, compressed: 1),
         file_path <- Path.join(path, @data_file_name),
         :ok <- File.write(file_path, encoded) do
      :ok
    else
      false ->
        {:error, "No chain path exists"}

      {:error, err} ->
        {:error, err}

      err ->
        err
    end
  end

  @doc """
  Read all additional information that is stored with chain
  """
  @spec read_external_data(evm_id()) :: {:ok, nil | map} | {:error, term}
  def read_external_data(id) do
    path =
      id
      |> evm_db_path()
      |> Path.join(@data_file_name)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         data <- :erlang.binary_to_term(content, [:safe]) do
      {:ok, data}
    else
      false ->
        {:ok, nil}

      {:error, err} ->
        {:error, err}
    end
  end

  @doc """
  Load list of evms version used in app
  """
  @spec version() :: binary
  def version() do
    {:ok, v} = :application.get_key(:ex_chain, :vsn)

    """

    Application version: #{to_string(v)}

    ==========================================
    #{Geth.version()}
    ==========================================
    #{Ganache.version()}
    ==========================================
    """
  end

  # Try lo load pid by given id
  defp get_pid(id) do
    case Registry.lookup(EvmRegistry, id) do
      [{pid, _}] ->
        pid

      _ ->
        nil
    end
  end

  # Same as `get_pid\1` but will raise in case of issue
  defp get_pid!(id) do
    case get_pid(id) do
      nil ->
        raise "No pid found"

      pid ->
        pid
    end
  end

  # Generate EVM DB path for chain
  defp evm_db_path(id) do
    Application.get_env(:ex_chain, :base_path, "/tmp")
    |> Path.expand()
    |> Path.join(id)
  end

  # Try to start evm using given module/config
  defp start_evm(module, %Config{id: nil} = config),
    do: start_evm(module, %Config{config | id: unique_id()})

  # if no db_path configured - system will geenrate new one
  defp start_evm(module, %Config{id: id, db_path: ""} = config) do
    path = evm_db_path(id)
    Logger.debug("#{id}: Chain DB path not configured will generate #{path}")
    start_evm(module, %Config{config | db_path: path})
  end

  defp start_evm(module, config), do: start_evm_process(module, config)

  # Starts new EVM genserver inser default supervisor
  defp start_evm_process(module, %Config{} = config) do
    config = fix_path(config)

    %Config{id: id, db_path: db_path} = config

    unless File.exists?(db_path) do
      Logger.debug("#{id}: #{db_path} not exist, creating...")
      :ok = File.mkdir_p!(db_path)
    end

    if snapshot_id = Map.get(config, :snapshot_id) do
      Logger.debug("#{id}: snapshot #{snapshot_id} should be loaded before chain start")
      load_restore_snapshot(snapshot_id, db_path)
    end

    case EvmSupervisor.start_evm(module, config) do
      {:ok, _pid} ->
        {:ok, id}

      _ ->
        {:error, "Something went wrong on starting chain"}
    end
  end

  # Load and restore snapshot to given path
  defp load_restore_snapshot(snapshot_id, db_path) do
    case SnapshotManager.by_id(snapshot_id) do
      nil ->
        :ok

      %Details{} = snapshot ->
        try do
          SnapshotManager.restore_snapshot!(snapshot, db_path)
        rescue
          _ ->
            {:error, "failed to restore snapshot #{snapshot_id}"}
        end
    end
  end

  # Expands path like `~/something` to normal path
  # This function is handler for `output: nil`
  defp fix_path(%{db_path: db_path, output: nil} = config),
    do: %Config{config | db_path: Path.expand(db_path)}

  defp fix_path(%{db_path: db_path, output: ""} = config),
    do: fix_path(%Config{config | output: "#{db_path}/out.log"})

  defp fix_path(%{db_path: db_path, output: output} = config),
    do: %Config{config | db_path: Path.expand(db_path), output: Path.expand(output)}
end
