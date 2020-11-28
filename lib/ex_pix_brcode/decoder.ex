defmodule ExPixBRCode.Decoder do
  @moduledoc """
  Decode iodata that represent a BRCode.
  """

  alias Ecto.Changeset

  alias ExPixBRCode.Models.BRCode

  @keys %{
    "00" => "payload_format_indicator",
    "01" => "point_of_initiation_method",
    "26" =>
      {"merchant_account_information",
       %{
         "00" => "gui",
         "01" => "chave",
         "25" => "url"
       }},
    "52" => "merchant_category_code",
    "53" => "transaction_currency",
    "54" => "transaction_amount",
    "58" => "country_code",
    "59" => "merchant_name",
    "60" => "merchant_city",
    "61" => "postal_code",
    "62" => {"additional_data_field_template", %{"05" => "reference_label"}},
    "63" => "crc",
    "80" => {"unreserved_templates", %{"00" => "gui"}}
  }

  @doc """
  Decode input into a map with string keys with known keys for Brocade.

  There is no actual validation about the values. If you want to coerce values and validate see 
  `decode_to/3` function.

  ## Errors

  Known validation errors result in a tuple with `{:validation, reason}`. Reason might be an atom 
  or a string.

  ## Options

  The following options are currently supported:

    - `strict_validation` (`t:boolean()` - default `false`): whether to allow unknown values or not

  ## Example

      iex> brcode = "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-426655440000" <> 
      ...> "5204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D"
      ...> decode(brcode)
      {:ok, %{"additional_data_field_template" => "0503***",
               "country_code" => "BR",
               "crc" => "1D3D",
               "merchant_account_information" => %{
                 "gui" => "br.gov.bcb.pix",
                 "key" => "123e4567-e12b-12d1-a456-426655440000"
               },
               "merchant_category_code" => "0000",
               "merchant_city" => "BRASILIA",
               "merchant_name" => "Fulano de Tal",
               "payload_format_indicator" => "01",
               "transaction_currency" => "986"
             }}
  """
  @spec decode(input :: iodata(), Keyword.t()) ::
          {:ok, term()} | {:error, {:validation, atom() | String.t()} | :unknown_error}
  def decode(input, opts \\ []) do
    brcode = IO.iodata_to_binary(input)
    {contents, crc} = String.split_at(brcode, -4)

    check_crc = contents |> CRC.ccitt_16() |> Integer.to_string(16) |> String.pad_leading(4, "0")

    if check_crc == crc do
      do_parse(brcode, opts)
    else
      {:error, :invalid_crc}
    end
  end

  @doc """
  Decode an iodata to a given schema module.

  This calls `decode/2` and then casts it into an `t:Ecto.Schema` module.

  It must have a changeset/2 public function.
  """
  @spec decode_to(input :: iodata(), Keyword.t(), schema :: module()) ::
          {:ok, struct()} | {:error, term()}
  def decode_to(input, opts \\ [], schema \\ BRCode) do
    case decode(input, opts) do
      {:ok, result} ->
        schema
        |> struct([])
        |> schema.changeset(result)
        |> case do
          %{valid?: true} = c -> {:ok, Changeset.apply_changes(c)}
          error -> {:error, {:validation, error}}
        end

      err ->
        err
    end
  end

  defp do_parse(brcode, opts) do
    graphemes = String.graphemes(brcode)

    case do_parse_graphemes(graphemes, opts, @keys, %{}) do
      {:error, _} = err -> err
      result when is_map(result) -> {:ok, result}
    end
  end

  defp do_parse_graphemes([], _opts, _keys, acc), do: acc

  defp do_parse_graphemes([k1, k2, s1, s2 | rest], opts, keys, acc) do
    key = Enum.join([k1, k2])
    size = Enum.join([s1, s2])

    with {:parsed_size, {size, ""}} <- {:parsed_size, Integer.parse(size)},
         {:value, {value, rest}} <- {:value, Enum.split(rest, size)} do
      case Map.get(keys, key) do
        {key, sub_keys} ->
          value = do_parse_graphemes(value, opts, sub_keys, %{})
          acc = Map.put(acc, key, value)
          do_parse_graphemes(rest, opts, keys, acc)

        key when is_binary(key) ->
          acc = Map.put(acc, key, Enum.join(value))
          do_parse_graphemes(rest, opts, keys, acc)

        nil ->
          if Keyword.get(opts, :strict_validation, false) do
            do_parse_graphemes(rest, opts, keys, acc)
          else
            {:error, {:validation, {:unknown_key, key}}}
          end
      end
    else
      {:parsed_size, :error} -> {:error, {:validation, :size_not_an_integer}}
      error -> {:error, {:unknown_error, error}}
    end
  end

  defp do_parse_graphemes(_, _, _, _), do: {:error, {:validation, :invalid_tag_length_value}}
end
