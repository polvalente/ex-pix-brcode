defmodule ExPixBRCode.DynamicPIXLoader do
  @moduledoc """
  Load a `t:ExPixBRCode.Models.PixPayment` from a url.

  Dynamic payments have a URL inside their text representation which we should use to 
  validate the certificate chain and signature and fill a PIXPayment model.
  """

  alias ExPixBRCode.{Changesets, JWKSStorage}
  alias ExPixBRCode.Models.{JWKS, JWSHeaders, PixPayment}

  defguardp is_success(status) when status >= 200 and status < 300

  @doc """
  Given a `t:Tesla.Client` and a PIX payment URL it loads its details after validation.
  """
  @spec load_pix(Tesla.Client.t(), String.t()) :: {:ok, PixPayment.t()} | {:error, atom()}
  def load_pix(client, url) do
    case Tesla.get(client, url) do
      {:ok, %{status: status} = env} when is_success(status) ->
        do_process_jws(client, env.body)

      {:ok, _} ->
        {:error, :http_status_not_success}

      {:error, _} = err ->
        err
    end
  end

  defp do_process_jws(client, jws) do
    with {:ok, header_claims} <- Joken.peek_header(jws),
         {:ok, header_claims} <- Changesets.cast_and_apply(JWSHeaders, header_claims),
         {:ok, jwks_storage} <- fetch_jwks_storage(client, header_claims),
         :ok <- verify_certificate(jwks_storage.certificate),
         :ok <- verify_alg(jwks_storage.jwk, header_claims.alg),
         {:ok, payload} <-
           Joken.verify(jws, build_signer(jwks_storage.jwk, header_claims.alg)),
         {:ok, pix} <- Changesets.cast_and_apply(PixPayment, payload) do
      {:ok, pix}
    end
  end

  defp build_signer(jwk, alg) do
    %Joken.Signer{
      alg: alg,
      jwk: jwk,
      jws: JOSE.JWS.from_map(%{"alg" => alg})
    }
  end

  defp verify_alg(%{kty: {:jose_jwk_kty_ec, _}}, alg)
       when alg in ["ES256", "ES384", "ES512"],
       do: :ok

  defp verify_alg(%{kty: {:jose_jwk_kty_rsa, _}}, alg)
       when alg in ["PS256", "PS384", "PS512", "RS256", "RS384", "RS512"],
       do: :ok

  defp verify_alg(_jwk, _alg) do
    {:error, :invalid_token_signing_algorithm}
  end

  defp verify_certificate(certificate) do
    {:Validity, not_before, not_after} = X509.Certificate.validity(certificate)

    not_before_check = DateTime.compare(DateTime.utc_now(), X509.DateTime.to_datetime(not_before))
    not_after_check = DateTime.compare(DateTime.utc_now(), X509.DateTime.to_datetime(not_after))

    cond do
      not_before_check not in [:gt, :eq] -> {:error, :certificate_not_yet_valid}
      not_after_check not in [:lt, :eq] -> {:error, :certificate_expired}
      true -> :ok
    end
  end

  defp fetch_jwks_storage(client, header_claims) do
    case JWKSStorage.jwks_storage_by_jws_headers(header_claims) do
      nil ->
        try_fetching_signers(client, header_claims)

      storage_item ->
        {:ok, storage_item}
    end
  end

  defp try_fetching_signers(client, header_claims) do
    case Tesla.get(client, header_claims.jku) do
      {:ok, %{status: status} = env} when is_success(status) ->
        process_jwks(env.body, header_claims)

      {:ok, _} ->
        {:error, :http_status_not_success}

      {:error, _} = err ->
        err
    end
  end

  defp process_jwks(jwks, header_claims) when is_binary(jwks) do
    case Jason.decode(jwks) do
      {:ok, jwks} when is_map(jwks) -> process_jwks(jwks, header_claims)
      {:error, _} = err -> err
      {:ok, _} -> {:error, :invalid_jwks_contents}
    end
  end

  defp process_jwks(jwks, header_claims) when is_map(jwks) do
    with {:ok, jwks} <- Changesets.cast_and_apply(JWKS, jwks),
         :ok <- JWKSStorage.process_keys(jwks.keys, header_claims.jku),
         storage_item when not is_nil(storage_item) <-
           JWKSStorage.jwks_storage_by_jws_headers(header_claims) do
      {:ok, storage_item}
    else
      nil -> {:error, :key_not_found_in_jku}
      err -> err
    end
  end
end
