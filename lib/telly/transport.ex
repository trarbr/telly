defmodule Telly.Transport do
  alias Telly.Transport

  defstruct endpoint: nil,
            handler: nil,
            serializer: nil,
            socket: nil,
            channels: %{},
            channels_inverse: %{}

  def new(endpoint, handler, serializer) do
    %Transport{
      endpoint: endpoint,
      handler: handler,
      serializer: serializer
    }
  end

  def connect(data, state) do
    params = Poison.decode!(data)

    case Phoenix.Socket.Transport.connect(
           state.endpoint,
           state.handler,
           :telnet,
           __MODULE__,
           state.serializer,
           params
         ) do
      {:ok, socket} ->
        # trap exits to avoid crashing if a channel process dies
        Process.flag(:trap_exit, true)
        if socket.id, do: socket.endpoint.subscribe(self(), socket.id, link: true)

        state = %{state | socket: socket}
        {:ok, state}

      :error ->
        :error
    end
  end

  def dispatch(data, state) do
    msg = state.socket.serializer.decode!(data, [])

    case Phoenix.Socket.Transport.dispatch(msg, state.channels, state.socket) do
      :noreply ->
        :noop

      {:reply, reply_msg} ->
        encode_reply(reply_msg, state)

      {:joined, channel_pid, reply_msg} ->
        state = put(state, msg.topic, channel_pid)
        encode_reply(reply_msg, state)

      {:error, _reason, error_reply_msg} ->
        encode_reply(error_reply_msg, state)
    end
  end

  def on_exit(channel_pid, reason, state) do
    case Map.get(state.channels_inverse, channel_pid) do
      nil ->
        :noop

      topic ->
        state = delete(state, topic, channel_pid)

        topic
        |> Phoenix.Socket.Transport.on_exit_message(reason)
        |> encode_reply(state)
    end
  end

  def close(state) do
    for {pid, _} <- state.channels_inverse do
      Phoenix.Channel.Server.close(pid)
    end
  end

  defp encode_reply(reply, state) do
    {:socket_push, _encoding, payload} = state.socket.serializer.encode!(reply)
    {:socket_push, payload, state}
  end

  defp put(state, topic, channel_pid) do
    %{
      state
      | channels: Map.put(state.channels, topic, channel_pid),
        channels_inverse: Map.put(state.channels_inverse, channel_pid, topic)
    }
  end

  defp delete(state, topic, channel_pid) do
    %{
      state
      | channels: Map.delete(state.channels, topic),
        channels_inverse: Map.delete(state.channels_inverse, channel_pid)
    }
  end
end
