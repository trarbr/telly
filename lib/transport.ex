defmodule Telly.Transport do
  use GenServer
  @behaviour :ranch_protocol

  def start_link(ref, tcp_socket, tcp_transport, opts \\ []) do
    :proc_lib.start_link(__MODULE__, :init, [ref, tcp_socket, tcp_transport, opts])
  end

  def default_config() do
    [serializer: Phoenix.Transports.WebSocketSerializer,
     telly: Telly.Transport]
  end

  def init(ref, tcp_socket, tcp_transport, opts) do
    :ok = :proc_lib.init_ack({:ok, self()})
    :ok = :ranch.accept_ack(ref)
    :ok = tcp_transport.setopts(tcp_socket, [{:active, :once}])
    state = %{
      tcp_transport: tcp_transport, # ranch_tcp in this case
      tcp_socket: tcp_socket, # the socket established by ranch
      endpoint: Keyword.fetch!(opts, :endpoint), # the Phoenix Endpoint
      handlers: Keyword.fetch!(opts, :handlers), # all sockets with a :telly handler
    }
    :gen_server.enter_loop(__MODULE__, [], state)
  end

  def handle_info({:tcp, _tcp_socket, data}, %{handlers: handlers} = state) do
    path = String.rstrip(data)

    case Map.fetch(handlers, path) do
      {:ok, {handler, serializer}} ->
        state = %{
          tcp_transport: state.tcp_transport,
          tcp_socket: state.tcp_socket,
          endpoint: state.endpoint,
          handler: handler,
          serializer: serializer
        }
        :ok = state.tcp_transport.setopts(state.tcp_socket, [active: :once])
        {:noreply, state}
      :error ->
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:tcp, tcp_socket, data}, %{tcp_transport: tcp_transport, endpoint: endpoint, handler: handler} = state) do
    params =
      String.rstrip(data)
      |> Poison.decode!()

    case Phoenix.Socket.Transport.connect(endpoint, handler, :telnet, __MODULE__, state.serializer, params) do
      {:ok, socket} ->
        Process.flag(:trap_exit, true) # trap exits to avoid crashing if a channel process dies
        if socket.id, do: socket.endpoint.subscribe(self(), socket.id, link: true)
        state = %{
          tcp_transport: tcp_transport,
          tcp_socket: tcp_socket,
          socket: socket,
          channels: %{},
          channels_inverse: %{}
        }
        :ok = tcp_transport.setopts(tcp_socket, [active: :once])
        tcp_transport.send(tcp_socket, "ok\r\n")
        {:noreply, state}
      :error ->
        tcp_transport.send(tcp_socket, "error\r\n")
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:tcp, _tcp_socket, data}, %{socket: socket} = state) do
    msg =
      String.rstrip(data)
      |> socket.serializer.decode!([])

    case Phoenix.Socket.Transport.dispatch(msg, state.channels, state.socket) do
      :noreply ->
        {:noreply, state}
      {:reply, reply_msg} ->
        encode_reply(reply_msg, state)
      {:joined, channel_pid, reply_msg} ->
        state = put(state, msg.topic, channel_pid)
        encode_reply(reply_msg, state)
      {:error, _reason, error_reply_msg} ->
        encode_reply(error_reply_msg, state)
    end
  end

  def handle_info({:EXIT, channel_pid, reason}, state) do
    case Map.get(state.channels_inverse, channel_pid) do
      nil -> {:noreply, state}
      topic ->
        state = delete(state, topic, channel_pid)
        Phoenix.Socket.Transport.on_exit_message(topic, reason)
        |> encode_reply(state)
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:socket_push, _encoding, _encoded_payload} = msg, state) do
    reply(msg, state)
  end

  def terminate(_reason, state) do
    if Map.get(state, :channels_inverse) do
      for {pid, _} <- state.channels_inverse do
        Phoenix.Channel.Server.close(pid)
      end
    end
    :ok
  end

  defp encode_reply(reply, state) do
    state.socket.serializer.encode!(reply)
    |> reply(state)
  end

  defp reply({:socket_push, _encoding, encoded_payload}, %{tcp_transport: transport, tcp_socket: socket} = state) do
    transport.send(socket, encoded_payload)
    transport.send(socket, "\r\n")
    :ok = transport.setopts(socket, [active: :once])
    {:noreply, state}
  end

  defp put(state, topic, channel_pid) do
    %{state | channels: Map.put(state.channels, topic, channel_pid),
              channels_inverse: Map.put(state.channels_inverse, channel_pid, topic)}
  end

  defp delete(state, topic, channel_pid) do
    %{state | channels: Map.delete(state.channels, topic),
              channels_inverse: Map.delete(state.channels_inverse, channel_pid)}
  end
end
