defmodule Telly.Supervisor do
  use Supervisor
  require Logger

  def start_link(endpoint, opts \\ []) do
    Supervisor.start_link(__MODULE__, endpoint, opts)
  end

  def init(endpoint) do
    socket_handlers =
      for {path, socket} <- endpoint.__sockets__,
          {_transport, {_module, config}} <- socket.__transports__,
          Telly.Transport == config[:telly],
          serializer = Keyword.fetch!(config, :serializer),
          into: %{},
          do: {path, {socket, serializer}}

    telly_spec =
      :ranch.child_spec(
        make_ref(),
        10,
        :ranch_tcp,
        [port: 5555],
        Telly.Protocol,
        endpoint: endpoint,
        handlers: socket_handlers
      )

    children = [telly_spec]

    Logger.info("Running Telly on port 5555")
    supervise(children, strategy: :one_for_one)
  end
end
