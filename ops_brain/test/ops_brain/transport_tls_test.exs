defmodule OpsBrain.TransportTLSTest do
  use OpsBrain.DataCase, async: false
  import OpsBrain.SourceFixtures
  def init(opts), do: opts

  def call(conn, _opts),
    do: Plug.Conn.send_resp(conn, 200, Jason.encode!(%{value: [], host: conn.host}))

  setup do
    f = fixture()
    on_exit(&cleanup/0)
    dir = Path.join(System.tmp_dir!(), "ops-brain-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    key = Path.join(dir, "key.pem")
    cert = Path.join(dir, "cert.pem")

    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca-key.pem")
    csr = Path.join(dir, "server.csr")
    ext = Path.join(dir, "extensions.cnf")

    File.write!(
      ext,
      "subjectAltName=DNS:ado.invalid\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          ca_key,
          "-out",
          ca,
          "-days",
          "1",
          "-subj",
          "/CN=Synthetic Test CA",
          "-addext",
          "basicConstraints=critical,CA:TRUE"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          csr,
          "-subj",
          "/CN=ado.invalid"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          cert,
          "-days",
          "1",
          "-extfile",
          ext
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    pid =
      start_supervised!(
        {Bandit,
         plug: __MODULE__,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         certfile: cert,
         keyfile: key,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    c =
      config(f, :a, %{
        endpoint: "https://ado.invalid:#{port}",
        approved_origins: ["https://ado.invalid:#{port}"],
        approved_ips: ["127.0.0.1"],
        ca_file: ca
      })

    Map.merge(f, %{c: c})
  end

  test "real Finch TLS request pins approved IP and verifies original hostname", f do
    port = URI.parse(f.c.endpoint).port

    assert {:ok, %{status: 200}} =
             Req.get(
               url: "https://127.0.0.1:#{port}/",
               connect_options: [
                 hostname: "ado.invalid",
                 transport_opts: [verify: :verify_peer, cacertfile: f.c.ca_file]
               ],
               retry: false
             )

    assert {:ok, %{status: 200, body: body}} =
             OpsBrain.Transport.get(
               f.c,
               "/#{f.c.organization}/#{f.c.project_id}/_apis/build/builds",
               []
             )

    assert %{"value" => [], "host" => "ado.invalid"} = Jason.decode!(body)
  end

  test "certificate hostname mismatch is not accepted", f do
    endpoint = String.replace(f.c.endpoint, "ado.invalid", "wrong.invalid")
    c = %{f.c | endpoint: endpoint, approved_origins: [endpoint]}
    Application.put_env(:ops_brain, :sources, %{c.id => c})

    assert {:error, :transport_unavailable} =
             OpsBrain.Transport.get(
               c,
               "/#{c.organization}/#{c.project_id}/_apis/build/builds",
               []
             )
  end
end
