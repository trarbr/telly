Telly
=====

Telly is a proof of concept telnet transport for the [Phoenix framework](http://www.phoenixframework.org/).

Please note that Telly is a work in progress: use at your own risk.

Installation
------------

Telly can be installed by adding it as a dependency in `mix.exs`:

```elixir
defp deps do
  [{:telly, github: "https://github.com/trarbr/telly"}]
end
```

Setup
-----

(If you just want to test it quickly, you can clone 
[this demo](https://github.com/trarbr/phoenix_chat_example) and skip to 
"Try it out".)

Add the Telly supervisor to your Phoenix application's top-level supervision tree,
next to the Endpoint and Repo supervisors. Assuming an app named `Chat`:

```elixir
defmodule Chat do
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
    # Start the endpoint when the application starts
    supervisor(Chat.Endpoint, []),      
    # Start the Ecto repository
    worker(Chat.Repo, []),
    # Start the Telly supervisor
    supervisor(Telly.Supervisor, [Chat.Endpoint, [name: Telly]]),
    ]

    opts = [strategy: :one_for_one, name: Chat.Supervisor]
    Supervisor.start_link(children, opts)   
  end
  # ... snip ...
end
```

Make sure there's a socket in `lib/endpoint.ex`:

```elixir
defmodule Chat.Endpoint do
  use Phoenix.Endpoint, otp_app: :chat

  socket "/socket", Chat.UserSocket
  # ... snip ...
end
```

Next, add a telnet transport to one of your sockets:

```elixir
defmodule Chat.UserSocket do
  use Phoenix.Socket

  channel "rooms:*", Chat.RoomChannel

  transport :websocket, Phoenix.Transports.WebSocket
  transport :longpoll, Phoenix.Transports.LongPoll
  transport :telnet, Telly.Transport

  def connect(_params, socket) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
```

Try it out
----------

First, start the application with `mix phoenix.server`. When started, it should
print `[info] Running Telly on port 5555` on the console.

You can now connect to your Phoenix application using `telnet localhost 5555`. At the
first prompt, enter the path of your socket and hit enter:

```
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
/socket
```

If you get the path wrong, the connection will be closed.

Next, enter a piece of JSON to use as `params` in your socket's connect/2
function. In this case I'll send an empty object:

```
... snip ...
/socket
{}
```

This time, the server should respond with "ok":

```
... snip ...
/socket
{}
ok
```

If connect/2 fails, it will respond with "error" instead, and close the connection.

If the server responds with "ok", you are now connected, and can join a topic by 
sending an appropriately formatted JSON message:

```
... snip ...
/socket
{}
ok
{"event": "phx_join", "topic": "rooms:lobby", "payload": null, "ref": "1234"}
```

The server will now send a reply with the same `ref`:

```
... snip ...
/socket
{}
ok
{"event": "phx_join", "topic": "rooms:lobby", "payload": null, "ref": "1234"}
{"topic":"rooms:lobby","ref":"1234","payload":{"status":"ok","response":{}},"event":"phx_reply"}
```

And you can send messages on the channel! For example:

```
{"topic":"rooms:lobby","ref":null,"payload":{"user":"","body":"How are you all doing?"},"event":"new:msg"}
```

Your telnet session can now communicate with all the other channels on the server.

About
-----

Telly was mainly written for educational purposes. I wanted to learn how
to write a new transport myself. I hope it can also help others understand 
what is needed to create new transports.
