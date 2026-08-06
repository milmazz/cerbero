defmodule Cerbero.SQL.Classifier do
  @moduledoc """
  Keyword-heuristic classification of raw SQL in `execute/1,2`. This is
  deliberately NOT a SQL parser: anchored patterns over normalized text,
  with `:unknown` as the honest fallback (surfaced as `unclassified_sql`).
  DML is *detected* (target table), never analyzed.

  Statement splitting, comment stripping, and quote tracking all happen in
  one pass (`scan/4`) so that `--`/`/* */` comments and `;` statement
  separators are only ever recognized outside of `'...'` strings, `"..."`
  identifiers, and `$tag$...$tag$` dollar-quoted blocks — and, conversely,
  so that quote/comment markers appearing *inside* a comment don't do
  anything either. The scanner also degrades gracefully (byte-for-byte,
  never raising) on invalid or truncated UTF-8; any statement that turns
  out not to be valid UTF-8 after splitting classifies as `:unknown`
  rather than being fed to `String.downcase/1` or `Regex`.

  Known limitation: escaped quotes (`''` inside a string literal, `""`
  inside a quoted identifier) are not understood — the scanner treats the
  first repeated quote as a close/open pair. This is rare in migration
  SQL and, worst case, degrades a statement to `:unknown` rather than
  misclassifying it as something actionable.
  """

  defmodule Classified do
    @moduledoc false
    defstruct class: :unknown,
              table: nil,
              column: nil,
              constraint: nil,
              concurrently: false,
              not_valid: false,
              unique: false,
              ref_table: nil
  end

  @ident ~S{((?:"[^"]+"|[a-z_][a-z0-9_$]*)(?:\.(?:"[^"]+"|[a-z_][a-z0-9_$]*))?)}

  @spec classify(String.t()) :: [%Classified{}]
  def classify(sql) when is_binary(sql) do
    sql
    |> split_statements()
    |> Enum.map(&classify_statement/1)
  end

  # Splits on top-level `;` only, with comments already stripped (replaced
  # by a single space, same as the old regex-based pass — just quote-aware
  # now). Semicolons and comment markers inside '...' strings, "..."
  # identifiers, or $tag$...$tag$ dollar-quoted blocks (e.g. a
  # `DO $$ BEGIN ...; END $$` function body, or a `--` sitting inside a
  # string literal) don't split or start a comment — a naive
  # `String.split(sql, ";")` plus a quote-blind comment regex would
  # misclassify a single dollar-quoted statement as two, or silently drop
  # a statement that follows a string literal containing `--`.
  defp split_statements(sql) do
    sql
    |> scan(:normal, [], [])
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp scan(<<>>, _state, current, stmts), do: [flush(current) | stmts]

  # -- quotes (only meaningful outside a comment/dollar-quote) -------------
  defp scan(<<?', rest::binary>>, :normal, current, stmts),
    do: scan(rest, :single_quote, [?' | current], stmts)

  defp scan(<<?', rest::binary>>, :single_quote, current, stmts),
    do: scan(rest, :normal, [?' | current], stmts)

  defp scan(<<?", rest::binary>>, :normal, current, stmts),
    do: scan(rest, :double_quote, [?" | current], stmts)

  defp scan(<<?", rest::binary>>, :double_quote, current, stmts),
    do: scan(rest, :normal, [?" | current], stmts)

  # -- statement separator (only meaningful outside quotes/comments) ------
  defp scan(<<?;, rest::binary>>, :normal, current, stmts),
    do: scan(rest, :normal, [], [flush(current) | stmts])

  # -- comment starts (only recognized in :normal) -------------------------
  defp scan(<<?-, ?-, rest::binary>>, :normal, current, stmts),
    do: scan(rest, :line_comment, [?\s | current], stmts)

  defp scan(<<?/, ?*, rest::binary>>, :normal, current, stmts),
    do: scan(rest, {:block_comment, 1}, [?\s | current], stmts)

  # -- dollar-quote start/continuation -------------------------------------
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
      case bin do
        <<c::utf8, rest::binary>> -> scan(rest, state, [<<c::utf8>> | current], stmts)
        <<byte, rest::binary>> -> scan(rest, state, [<<byte>> | current], stmts)
      end
    end
  end

  # -- line comment body: discard until (not including) `\n`, or EOF -------
  defp scan(<<?\n, _::binary>> = bin, :line_comment, current, stmts),
    do: scan(bin, :normal, current, stmts)

  defp scan(<<_c::utf8, rest::binary>>, :line_comment, current, stmts),
    do: scan(rest, :line_comment, current, stmts)

  defp scan(<<_byte, rest::binary>>, :line_comment, current, stmts),
    do: scan(rest, :line_comment, current, stmts)

  # -- block comment body: nesting is valid PG, so track depth -------------
  defp scan(<<?/, ?*, rest::binary>>, {:block_comment, depth}, current, stmts),
    do: scan(rest, {:block_comment, depth + 1}, current, stmts)

  defp scan(<<?*, ?/, rest::binary>>, {:block_comment, 1}, current, stmts),
    do: scan(rest, :normal, current, stmts)

  defp scan(<<?*, ?/, rest::binary>>, {:block_comment, depth}, current, stmts),
    do: scan(rest, {:block_comment, depth - 1}, current, stmts)

  defp scan(<<_c::utf8, rest::binary>>, {:block_comment, _} = state, current, stmts),
    do: scan(rest, state, current, stmts)

  defp scan(<<_byte, rest::binary>>, {:block_comment, _} = state, current, stmts),
    do: scan(rest, state, current, stmts)

  # -- generic character: append and stay in state (:normal / :single_quote
  # / :double_quote at this point) -----------------------------------------
  defp scan(<<c::utf8, rest::binary>>, state, current, stmts),
    do: scan(rest, state, [<<c::utf8>> | current], stmts)

  # -- invalid/truncated UTF-8 fallback: consume one raw byte and keep
  # going rather than crash. classify_statement/1 rejects the resulting
  # statement as :unknown if it isn't valid UTF-8 in the end. -------------
  defp scan(<<byte, rest::binary>>, state, current, stmts),
    do: scan(rest, state, [<<byte>> | current], stmts)

  defp flush(current), do: current |> Enum.reverse() |> IO.iodata_to_binary()

  defp dollar_tag(bin) do
    case Regex.run(~r/^\$([a-zA-Z_][a-zA-Z0-9_]*)?\$/, bin) do
      [tag | _] -> {tag, binary_part(bin, byte_size(tag), byte_size(bin) - byte_size(tag))}
      nil -> nil
    end
  end

  # Downcases everything except the contents of double-quoted identifiers:
  # Postgres folds bare identifiers to lowercase but is case-sensitive
  # inside quotes ("Flags" != flags), and our `table`/`column`/`constraint`
  # outputs come straight out of `unq/1` on the matched identifier text.
  defp normalize(stmt) do
    stmt
    |> selective_downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp selective_downcase(stmt) do
    Regex.replace(~r/"[^"]*"|[^"]+/, stmt, fn
      <<?", _::binary>> = quoted -> quoted
      chunk -> String.downcase(chunk)
    end)
  end

  defp classify_statement(stmt) do
    if String.valid?(stmt) do
      do_classify(normalize(stmt))
    else
      %Classified{class: :unknown}
    end
  end

  defp do_classify(n) do
    cond do
      m =
          run(
            ~r/^create (unique )?index (concurrently )?(?:if not exists )?(?:\S+ )?on (?:only )?#{@ident}/,
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
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:constraint (\S+) )?foreign key (?:\([^)]*\) )?references #{@ident}(?:\([^)]*\))?/,
            n
          ) ->
        %Classified{
          class: :add_foreign_key,
          table: unq(m[1]),
          constraint: unq(m[2]),
          ref_table: unq(m[3]),
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
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:constraint (\S+) )?primary key/,
            n
          ) ->
        %Classified{class: :add_primary_key, table: unq(m[1]), constraint: unq(m[2])}

      m =
          run(
            ~r/^alter table (?:only )?(?:if exists )?#{@ident} add (?:constraint (\S+) )?unique/,
            n
          ) ->
        %Classified{class: :add_unique, table: unq(m[1]), constraint: unq(m[2])}

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
