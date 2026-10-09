defmodule Licet.Schema.Parser do
  @moduledoc false

  import NimbleParsec

  alias Licet.Schema.Location

  @max_tokens 20_000

  whitespace = ascii_string([?\s, ?\t, ?\r, ?\n], min: 1)

  comment =
    string("//")
    |> repeat(ascii_char([{:not, ?\n}]))

  word =
    byte_offset(
      ascii_char([?a..?z])
      |> ascii_string([?a..?z, ?0..?9, ?_], min: 0, max: 63)
    )
    |> reduce(:pack_word)

  arrow = byte_offset(string("->")) |> reduce({:pack_sym, [:arrow]})
  wild = byte_offset(string(":*")) |> reduce({:pack_sym, [:wild]})
  lparen = byte_offset(string("(")) |> reduce({:pack_sym, [:lparen]})
  rparen = byte_offset(string(")")) |> reduce({:pack_sym, [:rparen]})
  lbrace = byte_offset(string("{")) |> reduce({:pack_sym, [:lbrace]})
  rbrace = byte_offset(string("}")) |> reduce({:pack_sym, [:rbrace]})
  colon = byte_offset(string(":")) |> reduce({:pack_sym, [:colon]})
  eq = byte_offset(string("=")) |> reduce({:pack_sym, [:eq]})
  plus = byte_offset(string("+")) |> reduce({:pack_sym, [:plus]})
  amp = byte_offset(string("&")) |> reduce({:pack_sym, [:amp]})
  minus = byte_offset(string("-")) |> reduce({:pack_sym, [:minus]})
  pipe = byte_offset(string("|")) |> reduce({:pack_sym, [:pipe]})
  slash = byte_offset(string("/")) |> reduce({:pack_sym, [:slash]})
  hash = byte_offset(string("#")) |> reduce({:pack_sym, [:hash]})
  dot = byte_offset(string(".")) |> reduce({:pack_sym, [:dot]})
  other = byte_offset(utf8_string([], 1)) |> reduce(:pack_other)

  defparsec(
    :scan,
    times(
      choice([
        ignore(whitespace),
        ignore(comment),
        arrow,
        wild,
        lparen,
        rparen,
        lbrace,
        rbrace,
        colon,
        eq,
        plus,
        amp,
        minus,
        pipe,
        slash,
        hash,
        dot,
        word,
        other
      ]),
      max: @max_tokens
    )
    |> eos()
  )

  @doc false
  @spec parse_schema(binary()) ::
          {:ok, [term()]} | {:error, binary(), pos_integer(), pos_integer()}
  def parse_schema(source) when is_binary(source) do
    case scan(source) do
      {:ok, tokens, "", _context, _line, _offset} ->
        case document(tokens) do
          {:ok, parts} -> {:ok, parts}
          {:error, message, offset} -> failure(source, message, offset)
        end

      {:error, message, _rest, _context, _line, offset} ->
        failure(source, message, offset)
    end
  end

  defp failure(source, message, offset) do
    {line, column} = Location.line_col(source, offset)
    {:error, message, line, column}
  end

  defp document(tokens) do
    with {:ok, expiration, tokens} <- use_expiration(tokens, false),
         {:ok, definitions, []} <- definitions(tokens, []) do
      {:ok, parts(expiration, definitions)}
    else
      {:ok, _definitions, [{:other, char, offset} | _rest]} ->
        {:error, "unexpected character #{char}", offset}

      {:ok, _definitions, [{_kind, _value, offset} | _rest]} ->
        {:error, "unexpected token", offset}

      {:error, _message, _offset} = error ->
        error
    end
  end

  defp parts(true, definitions), do: [:use_expiration | definitions]
  defp parts(false, definitions), do: definitions

  defp use_expiration([{:word, "use", _offset}, {:word, "expiration", _} | rest], false) do
    use_expiration(rest, true)
  end

  defp use_expiration([{:word, "use", offset}, {:word, "expiration", _} | _rest], true) do
    {:error, "use expiration is repeated", offset}
  end

  defp use_expiration([{:word, "use", _}, {:word, "self", offset} | _rest], _seen) do
    {:error, "self is not supported", offset}
  end

  defp use_expiration([{:word, "use", offset} | _rest], _seen) do
    {:error, "expected expiration", offset}
  end

  defp use_expiration(tokens, seen), do: {:ok, seen, tokens}

  defp definitions([{:word, "definition", _} | _] = tokens, acc) do
    with {:ok, definition, rest} <- definition(tokens) do
      definitions(rest, [definition | acc])
    end
  end

  defp definitions([{:word, "caveat", offset} | _rest], _acc) do
    {:error, "caveats are not supported", offset}
  end

  defp definitions(tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp definition([{:word, "definition", _} | tokens]) do
    with {:ok, type, tokens} <- type_name(tokens),
         {:ok, tokens} <- expect(tokens, :lbrace, "expected {"),
         {:ok, members, tokens} <- members(tokens, []),
         {:ok, tokens} <- expect(tokens, :rbrace, "expected }") do
      {:ok, definition_map(type, members), tokens}
    end
  end

  defp definition_map(type, members) do
    %{
      kind: :definition,
      name: type.name,
      offset: type.offset,
      segments: type.segments,
      members: members
    }
  end

  defp members([{:sym, :rbrace, _} | _] = tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp members([{:word, "relation", _} | tokens], acc) do
    with {:ok, relation, tokens} <- relation(tokens) do
      members(tokens, [relation | acc])
    end
  end

  defp members([{:word, "permission", _} | tokens], acc) do
    with {:ok, permission, tokens} <- permission(tokens) do
      members(tokens, [permission | acc])
    end
  end

  defp members([{_kind, _value, offset} | _rest], _acc) do
    {:error, "expected relation, permission, or }", offset}
  end

  defp members([], _acc), do: {:error, "expected }", 0}

  defp relation(tokens) do
    with {:ok, name, tokens} <- word(tokens),
         {:ok, tokens} <- expect(tokens, :colon, "expected :"),
         {:ok, subjects, tokens} <- subject_list(tokens) do
      {:ok, %{name: name.name, offset: name.offset, subjects: subjects}, tokens}
    end
  end

  defp permission(tokens) do
    with {:ok, name, tokens} <- word(tokens),
         {:ok, tokens} <- expect(tokens, :eq, "expected ="),
         {:ok, expr, tokens} <- expr(tokens) do
      {:ok, %{kind: :permission, name: name.name, offset: name.offset, expr: expr}, tokens}
    end
  end

  defp subject_list(tokens) do
    with {:ok, subject, tokens} <- subject(tokens) do
      more_subjects(tokens, [subject])
    end
  end

  defp more_subjects([{:sym, :pipe, _} | tokens], acc) do
    with {:ok, subject, tokens} <- subject(tokens) do
      more_subjects(tokens, [subject | acc])
    end
  end

  defp more_subjects(tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp subject(tokens) do
    with {:ok, type, tokens} <- type_name(tokens),
         {:ok, tail, tokens} <- subject_tail(tokens),
         {:ok, expiration, tokens} <- expiration_mark(tokens) do
      {:ok, subject_map(type, tail, expiration), tokens}
    end
  end

  defp subject_map(type, tail, expiration) do
    %{
      type: type.name,
      offset: type.offset,
      segments: type.segments,
      wildcard: tail == :wildcard,
      relation: subject_relation(tail),
      expiration: expiration
    }
  end

  defp subject_relation({:relation, name}), do: name
  defp subject_relation(_tail), do: nil

  defp subject_tail([{:sym, :wild, _} | tokens]), do: {:ok, :wildcard, tokens}

  defp subject_tail([{:sym, :hash, _offset}, {:word, name, _} | tokens]) do
    {:ok, {:relation, name}, tokens}
  end

  defp subject_tail([{:sym, :hash, offset} | _rest]),
    do: {:error, "expected subject relation", offset}

  defp subject_tail(tokens), do: {:ok, nil, tokens}

  defp expiration_mark([{:word, "with", _}, {:word, "expiration", _}, {:word, "and", offset} | _]) do
    {:error, "caveats are not supported", offset}
  end

  defp expiration_mark([{:word, "with", _offset}, {:word, "expiration", _} | tokens]) do
    {:ok, true, tokens}
  end

  defp expiration_mark([{:word, "with", _}, {:word, _caveat, offset} | _rest]) do
    {:error, "caveats are not supported", offset}
  end

  defp expiration_mark([{:word, "with", offset} | _rest]) do
    {:error, "expected expiration", offset}
  end

  defp expiration_mark(tokens), do: {:ok, false, tokens}

  defp type_name([{:word, name, offset} | tokens]), do: type_rest(tokens, [name], offset)
  defp type_name([{_kind, _value, offset} | _rest]), do: {:error, "expected a name", offset}
  defp type_name([]), do: {:error, "expected a name", 0}

  defp type_rest([{:sym, :slash, _}, {:word, name, _} | tokens], segments, offset) do
    type_rest(tokens, segments ++ [name], offset)
  end

  defp type_rest(tokens, segments, offset) do
    {:ok, %{name: Enum.join(segments, "/"), offset: offset, segments: segments}, tokens}
  end

  defp expr(tokens), do: exclusion(tokens)

  defp exclusion(tokens) do
    with {:ok, left, tokens} <- intersection(tokens) do
      exclusion_rest(left, tokens)
    end
  end

  defp exclusion_rest(left, [{:sym, :minus, _} | tokens]) do
    with {:ok, right, tokens} <- intersection(tokens) do
      exclusion_rest({:exclusion, left, right}, tokens)
    end
  end

  defp exclusion_rest(left, tokens), do: {:ok, left, tokens}

  defp intersection(tokens) do
    with {:ok, left, tokens} <- union(tokens) do
      intersection_rest(left, tokens)
    end
  end

  defp intersection_rest(left, [{:sym, :amp, _} | tokens]) do
    with {:ok, right, tokens} <- union(tokens) do
      intersection_rest({:intersection, left, right}, tokens)
    end
  end

  defp intersection_rest(left, tokens), do: {:ok, left, tokens}

  defp union(tokens) do
    with {:ok, left, tokens} <- arrow(tokens) do
      union_rest(left, tokens)
    end
  end

  defp union_rest(left, [{:sym, :plus, _} | tokens]) do
    with {:ok, right, tokens} <- arrow(tokens) do
      union_rest({:union, left, right}, tokens)
    end
  end

  defp union_rest(left, tokens), do: {:ok, left, tokens}

  defp arrow(tokens) do
    with {:ok, left, tokens} <- primary(tokens) do
      arrow_rest(left, tokens)
    end
  end

  defp arrow_rest(left, [{:sym, :arrow, _} | tokens]) do
    with {:ok, right, tokens} <- primary(tokens) do
      arrow_rest({:arrow, left, right}, tokens)
    end
  end

  defp arrow_rest(left, [
         {:sym, :dot, _},
         {:word, function, _},
         {:sym, :lparen, _},
         {:word, name, offset},
         {:sym, :rparen, _} | tokens
       ])
       when function in ["any", "all"] do
    arrow_rest({arrow_function(function), left, {:name, name, offset}}, tokens)
  end

  defp arrow_rest(_left, [{:sym, :dot, offset} | _tokens]) do
    {:error, "expected .any(name) or .all(name)", offset}
  end

  defp arrow_rest(left, tokens), do: {:ok, left, tokens}

  defp arrow_function("any"), do: :arrow
  defp arrow_function("all"), do: :arrow_all

  defp primary([{:sym, :lparen, _} | tokens]) do
    with {:ok, inner, tokens} <- expr(tokens),
         {:ok, tokens} <- expect(tokens, :rparen, "expected )") do
      {:ok, inner, tokens}
    end
  end

  defp primary([{:word, "nil", offset} | tokens]), do: {:ok, {:nil_expr, offset}, tokens}
  defp primary([{:word, "self", offset} | _tokens]), do: {:error, "self is not supported", offset}
  defp primary([{:word, name, offset} | tokens]), do: {:ok, {:name, name, offset}, tokens}
  defp primary([{_kind, _value, offset} | _rest]), do: {:error, "expected an expression", offset}
  defp primary([]), do: {:error, "expected an expression", 0}

  defp word([{:word, name, offset} | tokens]), do: {:ok, %{name: name, offset: offset}, tokens}
  defp word([{_kind, _value, offset} | _rest]), do: {:error, "expected a name", offset}
  defp word([]), do: {:error, "expected a name", 0}

  defp expect([{:sym, kind, _} | rest], kind, _message), do: {:ok, rest}
  defp expect([{_token, _value, offset} | _rest], _kind, message), do: {:error, message, offset}
  defp expect([], _kind, message), do: {:error, message, 0}

  defp pack_word([{[first, rest], ending}]) do
    name = IO.iodata_to_binary([first, rest])
    {:word, name, ending - byte_size(name)}
  end

  defp pack_sym([{[bin], ending}], kind) when is_binary(bin) do
    {:sym, kind, ending - byte_size(bin)}
  end

  defp pack_other([{[bin], ending}]), do: {:other, bin, ending - byte_size(bin)}
end
