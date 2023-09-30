defmodule Llama.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      LlamaWeb.Telemetry,
      {Nx.Serving, serving: llama(), name: ChatServing},
      # Start the PubSub system
      {Phoenix.PubSub, name: Llama.PubSub},
      # Start Finch
      {Finch, name: Llama.Finch},
      # Start the Endpoint (http/https)
      LlamaWeb.Endpoint
      # Start a worker by calling: Llama.Worker.start_link(arg)
      # {Llama.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Llama.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def llama() do
    auth_token = System.fetch_env!("HF_AUTH_TOKEN")
    llama = {:hf, "meta-llama/Llama-2-7b-chat-hf", auth_token: auth_token}

    {:ok, model_info} = Bumblebee.load_model(llama, backend: {EXLA.Backend, client: :host})
    {:ok, tokenizer} = Bumblebee.load_tokenizer(llama)
    {:ok, generation_config} = Bumblebee.load_generation_config(llama)

    generation_config = Bumblebee.configure(generation_config, max_new_tokens: 250)
    Bumblebee.Text.generation(model_info, tokenizer, generation_config, defn_options: [compiler: EXLA])
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LlamaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
