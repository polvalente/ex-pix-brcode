defmodule ExPixBRCode.Models.BRCode do
  @moduledoc """
  Schema for BRCode
  """

  use Ecto.Schema
  import Ecto.Changeset

  @required [
    :payload_format_indicator,
    :merchant_name,
    :merchant_city,
    :merchant_category_code,
    :transaction_currency,
    :country_code,
    :crc
  ]
  @optional [
    :point_of_initiation_method,
    :transaction_amount,
    :postal_code
  ]

  @primary_key false

  embedded_schema do
    field :payload_format_indicator, :string, default: "01"
    field :point_of_initiation_method, :string

    embeds_one :merchant_account_information, MerchantAccountInfo, primary_key: false do
      field :gui, :string, default: "br.gov.bcb.pix"

      # Static fields
      field :chave, :string
      field :info_adicional, :string

      # Dynamic fields
      field :url, :string
    end

    field :merchant_category_code, :string, default: "0000"

    field :transaction_currency, :string, default: "986"
    field :transaction_amount, :string
    field :country_code, :string, default: "BR"
    field :merchant_name, :string
    field :merchant_city, :string
    field :postal_code, :string

    embeds_one :additional_data_field_template, AdditionalDataField, primary_key: false do
      field :reference_label, :string
    end

    # Fields that are NOT "castable"
    field :crc, :string

    field :type, Ecto.Enum,
      values: [
        :static,
        :dynamic_payment_immediate,
        :dynamic_payment_with_due_date
      ]
  end

  @doc false
  def changeset(model \\ %__MODULE__{}, params) do
    model
    |> cast(params, @required ++ @optional)
    |> cast_embed(:merchant_account_information,
      with: &validate_merchant_acc_info/2,
      required: true
    )
    |> cast_embed(:additional_data_field_template,
      with: &validate_additional_data_field_template/2,
      required: true
    )
    |> validate_required(@required)
    |> validate_inclusion(:payload_format_indicator, ["01"])
    |> validate_inclusion(:point_of_initiation_method, ["12"])
    |> validate_format(:merchant_category_code, ~r/^[0-9]{4}$/)
    |> validate_inclusion(:transaction_currency, ["986"])
    |> validate_inclusion(:country_code, ["BR"])
    |> validate_length(:postal_code, is: 8)
    |> put_type()
  end

  defp put_type(%{valid?: false} = c), do: c

  defp put_type(changeset) do
    mai = get_field(changeset, :merchant_account_information)

    cond do
      not is_nil(mai.chave) ->
        put_change(changeset, :type, :static)

      not is_nil(mai.url) and String.ends_with?(String.downcase(mai.url), "/cobv") ->
        put_change(changeset, :type, :dynamic_payment_with_due_date)

      not is_nil(mai.url) ->
        put_change(changeset, :type, :dynamic_payment_immediate)
    end
  end

  defp validate_merchant_acc_info(model, params) do
    model
    |> cast(params, [:gui, :chave, :url, :info_adicional])
    |> validate_required([:gui])
    |> validate_inclusion(:gui, ["br.gov.bcb.pix", "BR.GOV.BCB.PIX"])
    |> validate_length(:chave, min: 1, max: 77)
    |> validate_length(:info_adicional, min: 1, max: 72)
    |> validate_length(:url, min: 1, max: 77)
    |> validate_per_type()
  end

  defp validate_additional_data_field_template(model, params) do
    model
    |> cast(params, [:reference_label])
    |> validate_required([:reference_label])
    |> validate_length(:reference_label, min: 1, max: 25)
  end

  defp validate_per_type(%{valid?: false} = c), do: c

  defp validate_per_type(changeset) do
    chave = get_field(changeset, :chave)
    info_adicional = get_field(changeset, :info_adicional)
    url = get_field(changeset, :url)

    cond do
      is_nil(chave) and is_nil(url) ->
        add_error(changeset, :chave_or_url, ":chave or :url must be present")

      not is_nil(chave) and not is_nil(url) ->
        add_error(changeset, :chave_or_url, ":chave and :url are present")

      not is_nil(chave) ->
        validate_chave_and_info_adicional_length(changeset, chave, info_adicional)

      not is_nil(info_adicional) ->
        add_error(changeset, :url_and_info_adicional, ":url and :info_adicional are present")

      true ->
        validate_url(changeset, url)
    end
  end

  defp validate_chave_and_info_adicional_length(changeset, chave, info_adicional) do
    [chave, info_adicional]
    |> Enum.join()
    |> String.length()
    |> case do
      length when length > 99 ->
        add_error(
          changeset,
          :chave_and_info_adicional_length,
          "The full size of merchant_account_information cannot exceed 99 characters"
        )

      _ ->
        changeset
    end
  end

  defp validate_url(changeset, url) do
    case URI.parse("https://" <> url) do
      %{path: path} when is_binary(path) ->
        validate_pix_path(changeset, Path.split(path))

      _ ->
        add_error(changeset, :url, "malformed URL")
    end
  end

  defp validate_pix_path(changeset, ["/" | path]) when length(path) > 1, do: changeset
  defp validate_pix_path(changeset, _), do: add_error(changeset, :url, "Invalid PIX path")
end
