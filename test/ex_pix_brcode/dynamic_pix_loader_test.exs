defmodule ExPixBRCode.DynamicPIXLoaderTest do
  use ExUnit.Case, async: true

  alias ExPixBRCode.DynamicPIXLoader
  alias ExPixBRCode.Models.PixPayment
  alias ExPixBRCode.Models.PixPayment.{Calendario, Valor}

  @client Tesla.client([], Tesla.Mock)

  setup_all do
    ca_key = X509.PrivateKey.new_rsa(1024)

    ca =
      X509.Certificate.self_signed(
        ca_key,
        "/C=BR/ST=SP/L=Sao Paulo/O=Acme/CN=RSA Pix Root CA",
        template: :root_ca
      )

    my_key = X509.PrivateKey.new_rsa(1024)

    my_cert =
      my_key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new(
        "/C=BR/ST=RJ/L=Rio de Janeiro/O=PSP Bank/CN=PSP",
        ca,
        ca_key,
        extensions: [
          subject_alt_name:
            X509.Certificate.Extension.subject_alt_name(["somepixpsp.br", "www.somepixpsp.br"])
        ]
      )

    raw_cert = X509.Certificate.to_der(my_cert)

    x5c = [
      Base.encode64(raw_cert),
      ca |> X509.Certificate.to_der() |> Base.encode64()
    ]

    {_, pubkey_map} =
      my_cert
      |> X509.Certificate.public_key()
      |> JOSE.JWK.from_key()
      |> JOSE.JWK.to_map()

    thumbprint =
      :sha
      |> :crypto.hash(raw_cert)
      |> Base.url_encode64(padding: false)

    kid = Ecto.UUID.generate()

    pem = my_key |> JOSE.JWK.from_key() |> JOSE.JWK.to_pem()

    jku = "https://somepixpsp.br/pix/v2/certs"

    signer =
      Joken.Signer.create("RS256", %{"pem" => pem}, %{
        "x5t" => thumbprint,
        "kid" => kid,
        "jku" => jku
      })

    jwks = %{
      "keys" => [
        Map.merge(
          pubkey_map,
          %{
            "kid" => kid,
            "x5c" => x5c,
            "x5t" => thumbprint,
            "kty" => "RSA",
            "key_ops" => ["verify"]
          }
        )
      ]
    }

    {:ok, jku: jku, signer: signer, jwks: jwks}
  end

  describe "load_pix/2" do
    test "succeeds with example payment", %{jku: jku} = ctx do
      payment = build_pix_payment()
      pix_url = "https://somepixpsp.br/pix/v2/#{Ecto.UUID.generate()}"

      Tesla.Mock.mock(fn
        %{url: ^pix_url} ->
          %{}
          |> Joken.generate_and_sign!(payment, ctx.signer)
          |> Tesla.Mock.text(headers: [{"content-type", "application/jose"}])

        %{url: ^jku} ->
          Tesla.Mock.json(ctx.jwks)
      end)

      assert {:ok,
              %PixPayment{
                calendario: %Calendario{
                  apresentacao: ~U[2020-11-28 03:15:39Z],
                  criacao: ~U[2020-11-13 23:59:49Z],
                  expiracao: 86400
                },
                chave: "14413050762",
                devedor: nil,
                infoAdicionais: '',
                revisao: 0,
                solicitacaoPagador: nil,
                status: :ATIVA,
                txid: "4DE46328260C11EB91C04049FC2CA371",
                valor: %Valor{original: Decimal.new("1.00")}
              }} == DynamicPIXLoader.load_pix(@client, pix_url)

      x5t = ctx.jwks["keys"] |> hd() |> Map.get("x5t")
      kid = ctx.jwks["keys"] |> hd() |> Map.get("kid")
      key = {x5t, kid}
      assert %{^key => _} = :persistent_term.get(ctx.jku)
    end
  end

  defp build_pix_payment do
    %{
      calendario: %{
        apresentacao: "2020-11-28 03:15:39Z",
        criacao: "2020-11-13 23:59:49Z",
        expiracao: 86400
      },
      chave: "14413050762",
      devedor: nil,
      infoAdicionais: [],
      revisao: 0,
      solicitacaoPagador: nil,
      status: :ATIVA,
      txid: "4DE46328260C11EB91C04049FC2CA371",
      valor: %{original: "1.00"}
    }
  end
end
