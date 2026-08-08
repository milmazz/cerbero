defmodule Cerbero.Migration.Parser do
  @moduledoc """
  Static AST analysis of migration source. Never compiles or executes
  user code: Ecto's DSL macros call the private, repo-bound
  Ecto.Migration.Runner, so interception would mean replicating private
  API. Cost: dynamically-generated operations are invisible — they are
  emitted as %Unknown{}, never silence.
  """

  alias Cerbero.Migration
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier

  @spec parse_dir(Path.t()) :: {:ok, [Migration.t()]} | {:error, term()}
  def parse_dir(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case parse_file(path) do
        {:ok, migration} -> {:cont, {:ok, [migration | acc]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, migrations} -> {:ok, migrations |> Enum.reverse() |> Enum.sort_by(& &1.version)}
      other -> other
    end
  end

  @spec parse_file(Path.t()) :: {:ok, Migration.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, source} <- File.read(path) do
      parse_string(source, path)
    end
  end

  @spec parse_string(String.t(), Path.t()) :: {:ok, Migration.t()} | {:error, term()}
  def parse_string(source, file \\ "inline.exs") do
    case Code.string_to_quoted(source, columns: false) do
      {:ok, ast} -> build(ast, file)
      {:error, {meta, msg, token}} -> {:error, {:syntax, meta, to_string(msg) <> inspect(token)}}
    end
  end

  defp build(ast, file) do
    {module, body} = find_module(ast)

    with {:ok, attrs} <- attributes(body) do
      up_bodies = migration_bodies(body, [:up, :change])
      down_bodies = migration_bodies(body, [:down])

      operations = Enum.flat_map(up_bodies, &extract_ops/1)

      down_operations =
        Enum.flat_map(down_bodies, &extract_ops/1) ++ execute_down_ops(up_bodies)

      {:ok,
       %Migration{
         file: file,
         module: module,
         version: version_from(file),
         attrs: attrs,
         operations: operations,
         down_operations: down_operations
       }}
    end
  end

  defp version_from(file) do
    case Regex.run(~r/(\d{10,14})_/, Path.basename(file)) do
      [_, version] -> version
      nil -> nil
    end
  end

  defp find_module({:defmodule, _, [alias_ast, [do: body]]}), do: {Macro.to_string(alias_ast), body}

  # A file may define helper modules ahead of the actual migration module
  # (e.g. a shared fixture/support module). Prefer whichever top-level
  # module's body has `use Ecto.Migration`; only fall back to the first
  # module when none do, so a helper defined first never silently swallows
  # the real migration's operations.
  defp find_module({:__block__, _, nodes}) do
    modules =
      nodes
      |> Enum.filter(&match?({:defmodule, _, _}, &1))
      |> Enum.map(&find_module/1)

    Enum.find(modules, fn {_module, body} -> uses_ecto_migration?(body) end) ||
      List.first(modules) || {nil, nil}
  end

  defp find_module(_), do: {nil, nil}

  defp uses_ecto_migration?(body) do
    body
    |> block_nodes()
    |> Enum.any?(&match?({:use, _, [{:__aliases__, _, [:Ecto, :Migration]} | _]}, &1))
  end

  defp attributes(body) do
    body
    |> block_nodes()
    |> Enum.reduce_while({:ok, %Migration{}.attrs}, fn
      {:@, _, [{:disable_ddl_transaction, _, [true]}]}, {:ok, attrs} ->
        {:cont, {:ok, %{attrs | disable_ddl_transaction: true}}}

      {:@, _, [{:disable_migration_lock, _, [true]}]}, {:ok, attrs} ->
        {:cont, {:ok, %{attrs | disable_migration_lock: true}}}

      {:@, _, [{:cerbero_skip, _, [skips]}]}, {:ok, attrs} ->
        case decode_skips(skips) do
          {:ok, decoded} -> {:cont, {:ok, %{attrs | cerbero_skip: decoded}}}
          {:error, _} = e -> {:halt, e}
        end

      _node, acc ->
        {:cont, acc}
    end)
  end

  defp decode_skips(skips) when is_list(skips) do
    Enum.reduce_while(skips, {:ok, []}, fn
      {:{}, _, _}, _acc ->
        {:halt, {:error, :invalid_skip}}

      {check, reason}, {:ok, acc} when is_atom(check) and is_binary(reason) ->
        if String.trim(reason) == "" do
          {:halt, {:error, {:empty_skip_reason, check}}}
        else
          {:cont, {:ok, acc ++ [{check, reason}]}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_skip}}
    end)
  end

  defp decode_skips(_), do: {:error, :invalid_skip}

  # up/change bodies feed `operations`; down bodies feed `down_operations`
  # (judged only under mix cerbero.check --down).
  defp migration_bodies(body, names) do
    body
    |> block_nodes()
    |> Enum.flat_map(fn
      {:def, _, [{name, _, _}, [do: fun_body]]} ->
        if name in names, do: [fun_body], else: []

      _ ->
        []
    end)
  end

  # The rollback leg of two-arg execute ("up sql", "down sql") lives in
  # up/change bodies but runs only on rollback — it belongs to
  # down_operations. A non-literal down leg is Unknown there, same honesty
  # rule as everywhere else.
  defp execute_down_ops(up_bodies) do
    up_bodies
    |> Enum.flat_map(&block_nodes/1)
    |> Enum.flat_map(fn
      {:execute, meta, [_up, down_sql | _]} when is_binary(down_sql) ->
        [%Op.RawSQL{sql: down_sql, line: meta[:line], classified: Classifier.classify(down_sql)}]

      {:execute, meta, [_up, _dynamic_down | _]} ->
        [unknown(meta, "execute down leg with non-literal SQL")]

      _ ->
        []
    end)
  end

  defp block_nodes({:__block__, _, nodes}), do: nodes
  defp block_nodes(nil), do: []
  defp block_nodes(node), do: [node]

  defp extract_ops(fun_body) do
    fun_body
    |> block_nodes()
    |> Enum.map(&op/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- create/drop/alter/execute -------------------------------------------

  defp op({verb, meta, [{:table, _, [name | _]}, [do: table_body]]}) when verb in [:create, :create_if_not_exists] do
    %Op.CreateTable{table: name(name), line: meta[:line], columns: columns(table_body)}
  end

  defp op({verb, meta, [{:table, _, [name | _]}]}) when verb in [:create, :create_if_not_exists] do
    %Op.CreateTable{table: name(name), line: meta[:line], columns: []}
  end

  defp op({verb, meta, [{index_kind, _, index_args}]})
       when verb in [:create, :create_if_not_exists] and index_kind in [:index, :unique_index] do
    case index_args do
      [table, keys | rest] when is_list(keys) ->
        opts = List.first(rest) || []

        %Op.CreateIndex{
          table: name(table),
          keys: Enum.map(keys, &key_name/1),
          concurrently: literal_opt(opts, :concurrently, false),
          unique: index_kind == :unique_index or literal_opt(opts, :unique, false),
          line: meta[:line]
        }

      _ ->
        unknown(meta, "create index with dynamic arguments")
    end
  end

  defp op({verb, meta, [{:constraint, _, [table, cname | rest]}]}) when verb in [:create, :create_if_not_exists] do
    opts = List.first(rest) || []

    %Op.CreateConstraint{
      table: name(table),
      name: name(cname),
      check: literal_opt(opts, :check, nil),
      validate: literal_opt(opts, :validate, true),
      line: meta[:line]
    }
  end

  # `drop index(table, keys, opts)` puts `opts` *inside* the index call's own
  # argument list (`index_args`), not as a trailing arg to `drop` itself —
  # unlike `create index(...)`, there is nothing after the index call for
  # `drop` to carry. `index_args` is `[table]`, `[table, keys]`, or
  # `[table, keys, opts]`; only the last shape carries `concurrently`.
  defp op({drop, meta, [{index_kind, _, index_args}]})
       when drop in [:drop, :drop_if_exists] and index_kind in [:index, :unique_index] do
    [table | rest] = index_args

    opts =
      case rest do
        [_keys, opts] when is_list(opts) -> opts
        _ -> []
      end

    %Op.DropIndex{
      table: name(table),
      concurrently: literal_opt(opts, :concurrently, false),
      line: meta[:line]
    }
  end

  defp op({drop, meta, [{:table, _, [name | _]} | _]}) when drop in [:drop, :drop_if_exists] do
    %Op.DropTable{table: name(name), line: meta[:line]}
  end

  defp op({:alter, meta, [{:table, _, [name | _]}, [do: alter_body]]}) do
    %Op.AlterTable{table: name(name), line: meta[:line], ops: alter_ops(alter_body)}
  end

  defp op({:execute, meta, [sql | _down]}) when is_binary(sql) do
    %Op.RawSQL{sql: sql, line: meta[:line], classified: Classifier.classify(sql)}
  end

  defp op({:execute, meta, _dynamic}) do
    unknown(meta, "execute with non-literal SQL")
  end

  defp op({:rename, meta, [{:table, _, [name | _]} | _]}) do
    %Op.RenameOp{table: name(name), line: meta[:line]}
  end

  # Non-DDL statements that are safe to ignore in a migration body.
  defp op({fun, _meta, _args}) when fun in [:flush, :repo, :prefix, :timeout, :log], do: nil

  defp op(node) do
    meta = if is_tuple(node) and tuple_size(node) == 3, do: elem(node, 1), else: []
    unknown(meta, node |> Macro.to_string() |> String.slice(0, 80))
  end

  defp unknown(meta, description) do
    %Op.Unknown{line: meta[:line], description: description}
  end

  defp columns(table_body) do
    table_body
    |> block_nodes()
    |> Enum.flat_map(fn
      {:add, _, [col, type | rest]} ->
        [%{name: name(col), type: type_of(type), opts: keyword_opts(List.first(rest) || [])}]

      {:add, _, [col]} ->
        [%{name: name(col), type: nil, opts: []}]

      {:timestamps, _, _} ->
        [
          %{name: "inserted_at", type: :naive_datetime, opts: []},
          %{name: "updated_at", type: :naive_datetime, opts: []}
        ]

      _ ->
        []
    end)
  end

  defp alter_ops(alter_body) do
    alter_body
    |> block_nodes()
    |> Enum.map(fn
      {:add, _, [col, type | rest]} ->
        {:add_column, name(col), type_of(type), keyword_opts(List.first(rest) || [])}

      {:modify, _, [col, type | rest]} ->
        {:modify_column, name(col), type_of(type), keyword_opts(List.first(rest) || [])}

      {:remove, _, [col | _]} ->
        {:remove_column, name(col)}

      other ->
        {:unknown_alter, Macro.to_string(other)}
    end)
  end

  defp type_of({:references, _, [table | rest]}), do: {:references, name(table), keyword_opts(List.first(rest) || [])}

  defp type_of(type) when is_atom(type), do: type
  defp type_of({:__aliases__, _, _} = t), do: Macro.to_string(t)
  defp type_of(other), do: {:dynamic, Macro.to_string(other)}

  defp keyword_opts(opts) when is_list(opts) do
    Enum.map(opts, fn
      {k, {:fragment, _, [frag]}} when is_binary(frag) -> {k, {:fragment, frag}}
      {k, {_, _, _} = ast} -> {k, {:dynamic, Macro.to_string(ast)}}
      {k, v} -> {k, v}
    end)
  end

  defp keyword_opts(_), do: []

  defp literal_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) or is_binary(value) or is_nil(value) or is_number(value) ->
        value

      _dynamic ->
        default
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_expr), do: :expression

  defp name(n) when is_atom(n), do: Atom.to_string(n)
  defp name(n) when is_binary(n), do: n
  defp name({_, _, _} = ast), do: Macro.to_string(ast)
end
