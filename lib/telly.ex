defmodule Telly do
  @behaviour Phoenix.Socket.Transport

  def default_config() do
    [
      serializer: Phoenix.Transports.WebSocketSerializer,
      telly: Telly.Transport
    ]
  end
end
