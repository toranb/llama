defmodule LlamaWeb.PageLive do
  use LlamaWeb, :live_view

  @impl true
  def mount(_, _, socket) do
    messages = []
    model = Replicate.Models.get!("meta/llama-2-7b-chat")
    version = Replicate.Models.get_latest_version!(model)

    socket = socket |> assign(version: version, messages: messages, text: nil, query: nil, ocr: nil, llama: nil, question: nil, loading: false)

    {:ok, socket}
  end

  @impl true
  def handle_event("change_text", %{"message" => text}, socket) do
    socket = socket |> assign(text: text)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", _, %{assigns: %{loading: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => question}, socket) do
    path = "psql.pdf"
    messages = socket.assigns.messages
    new_messages = messages ++ [%{user_id: 1, text: question, inserted_at: DateTime.utc_now()}]

    query =
      Task.async(fn ->
        System.cmd("pdftoppm", [path] ++ ~w(demo -png))
      end)

    socket = socket |> assign(query: query, messages: new_messages, loading: true, text: nil, question: question)

    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, _}, socket) when socket.assigns.query.ref == ref do
    ocr =
      Task.async(fn ->
        System.cmd("tesseract", ~w(demo-1.png stdout))
      end)

    {:noreply, assign(socket, query: nil, ocr: ocr)}
  end

  @impl true
  def handle_info({ref, {context, 0}}, socket) when socket.assigns.ocr.ref == ref do
    # IO.inspect(context)
    question = socket.assigns.question
    version = socket.assigns.version

    prompt =
    """
    [INST] <<SYS>>
    You are an assistant for question-answering tasks. Use the following pieces of retrieved context to answer the question.
    If you do not know the answer, just say that you don't know. Use two sentences maximum and keep the answer concise.
    <</SYS>>
    Question: #{question}
    Context: #{context}[/INST]
    """

    llama =
      Task.async(fn ->
        {:ok, prediction} = Replicate.Predictions.create(version, %{prompt: prompt})
        Replicate.Predictions.wait(prediction)
      end)

    {:noreply, assign(socket, ocr: nil, llama: llama)}
  end

  @impl true
  def handle_info({ref, {:ok, prediction}}, socket) when socket.assigns.llama.ref == ref do
    text = Enum.join(prediction.output)
    messages = socket.assigns.messages
    new_messages = messages ++ [%{user_id: nil, text: text, inserted_at: DateTime.utc_now()}]

    {:noreply, assign(socket, llama: nil, messages: new_messages, loading: false, question: nil)}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col grow px-2 sm:px-4 lg:px-8 py-10">
      <div class="flex flex-col grow relative -mb-8 mt-2 mt-2">
        <div class="absolute inset-0 gap-4">
          <div class="h-full flex flex-col bg-white shadow-sm border rounded-md">
            <div class="grid-cols-4 h-full grid divide-x">
              <div class="block relative col-span-4">
                <div class="flex absolute inset-0 flex-col">
                  <div class="relative flex grow overflow-y-hidden">
                    <div class="pt-4 pb-1 px-4 flex flex-col grow overflow-y-auto">
                      <%= for message <- @messages do %>
                      <div :if={message.user_id != 1} class="my-2 flex flex-row justify-start space-x-1 self-start items-start">
                        <div class="flex flex-col space-y-0.5 self-start items-start">
                          <div class="bg-gray-200 text-gray-900 ml-0 mr-12 py-2 px-3 inline-flex text-sm rounded-lg whitespace-pre-wrap"><%= message.text %></div>
                          <div class="mx-1 text-xs text-gray-500"><%= Calendar.strftime(message.inserted_at, "%B %d, %-I:%M %p") %></div>
                        </div>
                      </div>
                      <div :if={message.user_id == 1} class="my-2 flex flex-row justify-start space-x-1 self-end items-end">
                        <div class="flex flex-col space-y-0.5 self-end items-end">
                          <div class="bg-purple-600 text-gray-50 ml-12 mr-0 py-2 px-3 inline-flex text-sm rounded-lg whitespace-pre-wrap"><%= message.text %></div>
                          <div class="mx-1 text-xs text-gray-500"><%= Calendar.strftime(message.inserted_at, "%B %d, %-I:%M %p") %></div>
                        </div>
                      </div>
                      <% end %>
                      <div :if={@loading} class="typing"><div class="typing__dot"></div><div class="typing__dot"></div><div class="typing__dot"></div></div>
                    </div>
                  </div>
                  <form class="px-4 py-2 flex flex-row items-end gap-x-2" phx-submit="add_message" phx-change="change_text">
                    <div class="flex flex-col grow rounded-md border border-gray-300">
                      <div class="relative flex grow">
                        <input id="message" name="message" value={@text} class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 text-sm placeholder:text-gray-400 text-gray-900" placeholder="Aa" type="text" />
                      </div>
                    </div>
                    <div class="ml-1">
                      <button type="submit" class="flex items-center justify-center h-10 w-10 rounded-full bg-gray-200 hover:bg-gray-300 text-gray-500">
                        <svg class="w-5 h-5 transform rotate-90 -mr-px" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path>
                        </svg>
                      </button>
                    </div>
                  </form>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
