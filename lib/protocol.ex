defmodule Telly.Protocol do
  @behaviour :ranch_protocol

  alias Telly.{Protocol, Transport}

  defstruct transport: nil,
            socket: nil,
            endpoint: nil,
            handlers: nil,
            status: :awaiting_handler,
            handler_state: nil

  def start_link(ref, socket, transport, opts \\ []) do
    :proc_lib.start_link(__MODULE__, :init, [[ref, socket, transport, opts]])
  end

  def init([ref, socket, transport, opts]) do
    :ok = :proc_lib.init_ack({:ok, self()})
    :ok = :ranch.accept_ack(ref)
    :ok = transport.setopts(socket, [{:active, :once}])

    state = %Protocol{
      # ranch_tcp in this case
      transport: transport,
      # the socket established by ranch
      socket: socket,
      # the Phoenix Endpoint
      endpoint: Keyword.fetch!(opts, :endpoint),
      # all sockets with a :telly handler
      handlers: Keyword.fetch!(opts, :handlers)
    }

    :gen_server.enter_loop(__MODULE__, [], state)
  end

  def handle_info({:tcp, _socket, data}, %{status: :awaiting_handler} = state) do
    path = String.trim_trailing(data)

    case Map.fetch(state.handlers, path) do
      {:ok, {handler, serializer}} ->
        handler_state = Transport.new(state.endpoint, handler, serializer)
        state = %{state | handler_state: handler_state, status: :awaiting_connect}

        :ok = state.transport.setopts(state.socket, active: :once)
        {:noreply, state}

      :error ->
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{status: :awaiting_connect} = state) do
    data = String.trim_trailing(data)

    case Transport.connect(data, state.handler_state) do
      {:ok, handler_state} ->
        state = %{state | handler_state: handler_state, status: :connected}
        do_socket_push("ok", state)

      :error ->
        state.transport.send(socket, "error\r\n")
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:tcp, _socket, data}, state) do
    data = String.trim_trailing(data)

    case Transport.dispatch(data, state.handler_state) do
      :noop ->
        {:noreply, state}

      {:socket_push, payload, handler_state} ->
        state = %{state | handler_state: handler_state}
        do_socket_push(payload, state)
    end
  end

  def handle_info({:EXIT, channel_pid, reason}, state) do
    case Transport.on_exit(channel_pid, reason, state.handler_state) do
      :noop ->
        {:noreply, state}

      {:socket_push, payload, handler_state} ->
        state = %{state | handler_state: handler_state}
        do_socket_push(payload, state)
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:socket_push, _encoding, payload}, state) do
    do_socket_push(payload, state)
  end

  def terminate(_reason, state) do
    Transport.close(state.handler_state)
    :ok
  end

  defp do_socket_push(payload, state) do
    state.transport.send(state.socket, [payload, "\r\n"])
    :ok = state.transport.setopts(state.socket, active: :once)
    {:noreply, state}
  end
end
