defmodule ExPixBRCode.JWKSStorage do
  @moduledoc """
  A JWKS storage of validated keys and certificates.
  """

  alias ExPixBRCode.Models.JWKS.Key
  alias ExPixBRCode.Models.JWSHeaders

  defstruct [:jwk, :certificate, :key]

  @typedoc """
  Storage item.

  It has a parsed JWK, the certificate of the key and the key parsed from the JWKS.
  We should always check the certificate validity before using the signer.
  """
  @type t() :: %__MODULE__{
          jwk: JOSE.JWK.t(),
          certificate: X509.Certificate.t(),
          key: Key.t()
        }

  @doc """
  Process validation and storage of keys.

  Keys in JWKS endpoints must pass the following validations:
    - Must be of either EC or RSA types
    - Must have the x5c claim
    - The first certificate in the x5c claim MUST have the same key parameters as the key in the
    root
    - The certificate thumbprint must match that of the first certificate in the chain

  After successful validation, keys are inserted in a `:persistent_term`.
  """
  @spec process_keys([Key.t()], jku :: String.t()) ::
          :ok
          | {:error,
             :key_thumbprint_and_first_certificate_differ
             | :key_from_first_certificate_differ
             | :invalid_certificate_encoding
             | :certificate_subject_and_jku_uri_authority_differs}
  def process_keys(keys, jku) when is_list(keys) do
    case Enum.reduce_while(keys, {:ok, []}, &validate_and_persist_key(&1, jku, &2)) do
      {:ok, keys} -> :persistent_term.put(jku, Map.new(keys))
      {:error, _} = err -> err
    end
  end

  defp validate_and_persist_key(%Key{x5c: [b64_cert | _] = chain} = key, jku, {:ok, acc}) do
    key_from_params = key |> build_key_map() |> JOSE.JWK.from_map()

    with {:ok, jwk} <- validate_certificate_chain(chain),
         {:ok, certificate} <- validate_leaf_certificate(b64_cert, jku, key.x5t),
         {:key_from_cert, true} <- {:key_from_cert, key_from_params == jwk} do
      storage_item = %__MODULE__{jwk: key_from_params, certificate: certificate, key: key}

      key = {key.x5t, key.kid}
      {:cont, {:ok, [{key, storage_item} | acc]}}
    else
      {:key_from_cert, false} -> {:halt, {:error, :key_from_leaf_certificate_differ}}
      {:error, _} = err -> {:halt, err}
      :error -> {:halt, {:error, :invalid_certificate_encoding}}
    end
  end

  def validate_leaf_certificate(b64_cert, jku, x5t) do
    with {:ok, raw_der} <- Base.decode64(b64_cert),
         {:ok, certificate} <- X509.Certificate.from_der(raw_der),
         :ok <- validate_cert_subject(certificate, jku),
         {:x5t, true} <- {:x5t, thumbprint(raw_der) == x5t} do
      {:ok, certificate}
    else
      {:x5t, false} -> {:error, :key_thumbprint_and_leaf_certificate_differ}
      :error -> :error
      {:error, _} = err -> err
    end
  end

  defp validate_certificate_chain(chain) do
    with {:ok, [root | certificate_chain]} <- decode_chain(chain),
         {:ok, {{_, pkey, _}, _}} <-
           :public_key.pkix_path_validation(root, certificate_chain, []) do
      {:ok, JOSE.JWK.from_key(pkey)}
    else
      :error -> {:error, :invalid_cert_encoding}
      {:error, _} = err -> err
    end
  end

  defp decode_chain(chain) when length(chain) > 1 do
    # This reverses the chain automatically
    Enum.reduce_while(chain, {:ok, []}, fn cert, {:ok, acc} ->
      case Base.decode64(cert) do
        {:ok, decoded_cert} -> {:cont, {:ok, [decoded_cert | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_chain(_), do: {:error, :x5c_must_have_more_than_one_cert}

  defp validate_cert_subject(certificate, jku) do
    jku = URI.parse(jku)

    [authority | _] =
      certificate
      |> X509.Certificate.subject()
      |> X509.RDNSequence.get_attr("commonName")

    {:Extension, {2, 5, 29, 17}, _, values} =
      X509.Certificate.extension(certificate, {2, 5, 29, 17})

    dns = Keyword.get(values, :dNSName, nil) |> to_string()

    if jku.authority == authority or jku.authority == dns do
      :ok
    else
      {:error, :certificate_subject_and_jku_uri_authority_differs}
    end
  end

  defp build_key_map(%{kty: "EC"} = key),
    do: %{"kty" => "EC", "crv" => key.crv, "x" => key.x, "y" => key.y}

  defp build_key_map(%{kty: "RSA"} = key),
    do: %{"kty" => "RSA", "n" => key.n, "e" => key.e}

  defp thumbprint(raw_cert, alg \\ :sha) do
    alg
    |> :crypto.hash(raw_cert)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Get the signer associated with the given 
  """
  @spec jwks_storage_by_jws_headers(JWSHeaders.t()) :: nil | __MODULE__.t()
  def jwks_storage_by_jws_headers(headers) do
    case :persistent_term.get(headers.jku, nil) do
      nil -> nil
      values -> Map.get(values, {headers.x5t, headers.kid})
    end
  end
end
