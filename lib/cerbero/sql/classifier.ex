defmodule Cerbero.SQL.Classifier do
  @moduledoc """
  Keyword-heuristic classification of raw SQL in `execute/1,2`. This is
  deliberately NOT a SQL parser: anchored patterns over normalized text,
  with `:unknown` as the honest fallback (surfaced as `unclassified_sql`).
  DML is *detected* (target table), never analyzed.
  """

  defmodule Classified do
    @moduledoc false
    defstruct class: :unknown,
              table: nil,
              column: nil,
              constraint: nil,
              concurrently: false,
              not_valid: false,
              unique: false
  end

  @ident ~S{((?:"[^"]+"|[a-z_][a-z0-9_$]*)(?:\.(?:"[^"]+"|[a-z_][a-z0-9_$]*))?)}

  @spec classify(String.t()) :: [%Classified{}]
  def classify(sql) when is_binary(sql) do
    sql
    |> strip_comments()
    |> split_statements()
    |> Enum.map(&classify_statement/1)
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, " ")
    |> String.replace(~r{/\*.*?\*/}s, " ")
  end

  # Splits on top-level `;` only. Semicolons inside '...' strings, "..."
  # identifiers, or $tag$...$tag$ dollar-quoted blocks (e.g. a
  # `DO $$ BEGIN ...; END $$` function body) don't terminate a statement —
  # a naive `String.split(sql, ";")` would misclassify a single dollar-quoted
  # statement as two.
  defp split_statements(sql) do
    sql
    |> scan(:normal, [], [])
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp scan(<<>>, _state, current, stmts), do: [flush(current) | stmts]

  defp scan(<<?', rest::binary>>, :normal, current, stmts),
    do: scan(rest, :single_quote, [?' | current], stmts)

  defp scan(<<?', rest::binary>>, :single_quote, current, stmts),
    do: scan(rest, :normal, [?' | current], stmts)

  defp scan(<<?", rest::binary>>, :normal, current, stmts),
    do: scan(rest, :double_quote, [?" | current], stmts)

  defp scan(<<?", rest::binary>>, :double_quote, current, stmts),
    do: scan(rest, :normal, [?" | current], stmts)

  defp scan(<<?;, rest::binary>>, :normal, current, stmts),
    do: scan(rest, :normal, [], [flush(current) | stmts])

  defp scan(<<?$, _::binary>> = bin, :normal, current, stmts) do
    case dollar_tag(bin) do
      {tag, rest} ->
        scan(rest, {:dollar, tag}, [tag | current], stmts)

      nil ->
        <<?$, rest::binary>> = bin
        scan(rest, :normal, [?$ | current], stmts)
    end
  end

  defp scan(bin, {:dollar, tag} = state, current, stmts) do
    if String.starts_with?(bin, tag) do
      rest = binary_part(bin, byte_size(tag), byte_size(bin) - byte_size(tag))
      scan(rest, :normal, [tag | current], stmts)
    else
      <<c::utf8, rest::binary>> = bin
      scan(rest, state, [<<c::utf8>> | current], stmts)
    end
  end

  defp scan(<<c::utf8, rest::binary>>, state, current, stmts),
    do: scan(rest, state, [<<c::utf8>> | current], stmts)

  defp flush(current), do: current |> Enum.reverse() |> IO.iodata_to_binary()

  defp dollar_tag(bin) do
    case Regex.run(~r/^\$([a-zA-Z_][a-zA-Z0-9_]*)?\$/, bin) do
      [tag | _] -> {tag, binary_part(bin, byte_size(tag), byte_size(bin) - byte_size(tag))}
      nil -> nil
    end
  end

  defp normalize(stmt) do
    stmt |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp classify_statement(stmt) do
    n = normalize(stmt)

    cond do
      m =
          run(
            ~r/^create (unique )?index (concurrently )?(?:if not exists )?\S+ on (?:only )?#{@ident}/,
            n
          ) ->
        %Classified{
          class: :create_index,
          unique: m[1] != "",
          concurrently: m[2] != "",
          table: unq(m[3])
        }

      m = run(~r/^drop index (concurrently )?(?:if exists )?#{@ident}/, n) ->
        %Classified{class: :drop_index, concurrently: m[1] != "", constraint: unq(m[2])}

      m = run(~r/^create table (?:if not exists )?#{@ident}/, n) ->
        %Classified{class: :create_table, table: unq(m[1])}

      m = run(~r/^drop table (?:if exists )?#{@ident}/, n) ->
        %Classified{class: :drop_table, table: unq(m[1])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add constraint (\S+) check \( ?(\S+) is not null ?\)( not valid)?/,
            n
          ) ->
        %Classified{
          class: :add_check_is_not_null,
          table: unq(m[1]),
          constraint: unq(m[2]),
          column: unq(m[3]),
          not_valid: m[4] != ""
        }

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} add constraint (\S+) check /, n) ->
        %Classified{
          class: :add_check,
          table: unq(m[1]),
          constraint: unq(m[2]),
          not_valid: String.ends_with?(n, "not valid")
        }

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:constraint (\S+) )?foreign key/,
            n
          ) ->
        %Classified{
          class: :add_foreign_key,
          table: unq(m[1]),
          constraint: unq(m[2]),
          not_valid: String.ends_with?(n, "not valid")
        }

      m = run(~r/^alter table (?:only )?(?:if exists )?#{@ident} validate constraint (\S+)/, n) ->
        %Classified{class: :validate_constraint, table: unq(m[1]), constraint: unq(m[2])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} alter column (\S+) set not null/,
            n
          ) ->
        %Classified{class: :set_not_null, table: unq(m[1]), column: unq(m[2])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} alter column (\S+) (?:set data )?type /,
            n
          ) ->
        %Classified{class: :alter_column_type, table: unq(m[1]), column: unq(m[2])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:column )?(?:if not exists )?(\S+) /,
            n
          ) ->
        %Classified{class: :add_column, table: unq(m[1]), column: unq(m[2])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} drop (?:column )?(?:if exists )?(\S+)/,
            n
          ) ->
        %Classified{class: :drop_column, table: unq(m[1]), column: unq(m[2])}

      m = run(~r/^truncate (?:table )?(?:only )?#{@ident}/, n) ->
        %Classified{class: :truncate, table: unq(m[1])}

      run(~r/^reindex /, n) ->
        %Classified{class: :reindex, concurrently: String.contains?(n, " concurrently")}

      m = run(~r/^update (?:only )?#{@ident} set /, n) ->
        %Classified{class: :update, table: unq(m[1])}

      m = run(~r/^delete from (?:only )?#{@ident}/, n) ->
        %Classified{class: :delete, table: unq(m[1])}

      m = run(~r/^insert into #{@ident}[\s\S]* select /, n) ->
        %Classified{class: :insert_select, table: unq(m[1])}

      true ->
        %Classified{class: :unknown}
    end
  end

  # Returns a 0-indexed capture map (m[0] is the full match, m[1].. are
  # capture groups) or nil.
  defp run(regex, string) do
    case Regex.run(regex, string) do
      nil -> nil
      captures -> captures |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c || ""} end)
    end
  end

  defp unq(nil), do: nil
  defp unq(""), do: nil
  defp unq(ident), do: ident |> String.replace("\"", "") |> String.trim_trailing(",")
end
