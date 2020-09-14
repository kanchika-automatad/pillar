defmodule Pillar.BulkInsertBuffer do
  @moduledoc """
  This module provides functionality for bulk inserts and buffering records

  ```elixir
    defmodule BulkToLogs do
      use Pillar.BulkInsertBuffer,
        pool: ClickhouseMaster,
        table_name: "logs",
        interval_between_inserts_in_seconds: 5
    end
  ```

  ```elixir
  :ok = BulkToLogs.insert(%{value: "online", count: 133, datetime: DateTime.utc_now()})
  :ok = BulkToLogs.insert(%{value: "online", count: 134, datetime: DateTime.utc_now()})
  :ok = BulkToLogs.insert(%{value: "online", count: 132, datetime: DateTime.utc_now()})
  ....

  # all this records will be inserted with 5 second interval
  ```
  """

  defmacro __using__(
             pool: pool_module,
             table_name: table_name,
             interval_between_inserts_in_seconds: seconds
           ) do
    quote do
      use GenServer
      import Supervisor.Spec

      def start_link(_any \\ nil) do
        name = __MODULE__
        pool = unquote(pool_module)
        table_name = unquote(table_name)
        records = []
        GenServer.start_link(__MODULE__, {{}, pool, table_name, records}, name: name)
      end

      def init(state) do
        schedule_work()
        {:ok, state}
      end

      def insert(data) when is_map(data) do
        GenServer.cast(__MODULE__, {:insert, data})
      end

      def force_bulk_insert do
        GenServer.call(__MODULE__, :do_insert)
      end

      def records_for_bulk_insert() do
        GenServer.call(__MODULE__, :records_for_bulk_insert)
      end

      def get_status() do
        pid = GenServer.whereis(__MODULE__)
        cur_status = :sys.get_state(pid)
        IO.inspect(length(elem(cur_status,3)))
        elem(cur_status,0)
      end

      def handle_call(:do_insert, _from, {rec, pool, table_name, records } =state) do
          new_state = do_bulk_insert(state)
          {:reply, elem(new_state,0), new_state}
      end

      def handle_cast({:insert, data}, { rec, pool, table_name, records} = state) do
        {:noreply, { rec, pool, table_name, Enum.uniq(records ++ List.wrap(data))}}
      end

      def handle_call(
            :records_for_bulk_insert,
            _from,
            {_pool, _table_name, records} = state
          ) do
        {:reply, records, state}
      end

      def handle_info(:cron_like_records, state) do
        new_state = do_bulk_insert(state)
        schedule_work()
        {:noreply, new_state}
      end

      defp schedule_work do
        seconds = unquote(seconds)
        Process.send_after(self(), :cron_like_records, :timer.seconds(seconds))
      end

      defp do_bulk_insert({{}, _pool, _table_name, []} = state) do
        state
      end

      # defp do_bulk_insert({{:ok,""}, _pool, _table_name, _k} = state) do
      #   {{}, _pool, _table_name, []}
      # end

      defp do_bulk_insert({_k, pool, table_name, records} = state) do
        # IO.inspect("bulk_insert")
        # IO.inspect(state)
        resp = pool.async_insert_to_table(table_name, records)
        if elem(resp,0) == :error and elem(resp,1).status_code != 400 do
          {
            resp,
            pool,
            table_name,
            records
          }
        else
          {
            resp,
            pool,
            table_name,
            []
          }
        end
      end
    end
  end
end
