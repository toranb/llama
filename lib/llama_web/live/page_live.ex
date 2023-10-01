defmodule LlamaWeb.PageLive do
  use LlamaWeb, :live_view

  @impl true
  def mount(_, _, socket) do
    messages = []
    model = Replicate.Models.get!("meta/llama-2-7b-chat")
    version = Replicate.Models.get_latest_version!(model)

    socket =
      socket
      |> assign(version: version, messages: messages, text: nil, query: nil, ocr: nil, llama: nil, question: nil, path: nil, loading: false, focused: false)
      |> allow_upload(:document, accept: ~w(.pdf), progress: &handle_progress/3, auto_upload: true, max_entries: 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("dragged", %{"focused" => focused}, socket) do
    {:noreply, assign(socket, focused: focused)}
  end

  @impl true
  def handle_event("remove_pdf", _, socket) do
    {:noreply, assign(socket, path: nil)}
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
  def handle_event("add_message", %{"message" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => question}, socket) do
    path = socket.assigns.path
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

    {:noreply, assign(socket, ocr: nil, question: nil, llama: llama)}
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

  def handle_progress(:document, %{client_name: filename} = entry, socket) when entry.done? do
    path =
      consume_uploaded_entries(socket, :document, fn %{path: path}, _entry ->
        dest = Path.join(["priv", "static", "uploads", Path.basename("#{path}/#{filename}")])
        File.cp!(path, dest)
        {:ok, dest}
      end)
      |> List.first()

    {:noreply, assign(socket, path: path)}
  end

  def handle_progress(_name, _entry, socket), do: {:noreply, socket}

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
                  <form class="px-4 py-2 flex flex-row items-end gap-x-2" phx-submit="add_message" phx-change="change_text" phx-drop-target={@uploads.document.ref}>
                    <.live_file_input class="sr-only" upload={@uploads.document} />
                    <div id="dragme" phx-hook="Drag" class={"flex flex-col grow rounded-md #{if !is_nil(@path), do: "border"} #{if @focused, do: "ring-1 border-indigo-500 ring-indigo-500 border"}"}>
                      <div :if={!is_nil(@path)} class="mx-2 mt-3 mb-2 flex flex-row items-center rounded-md gap-x-4 gap-y-3 flex-wrap">
                        <div class="relative">
                          <div class="px-2 h-14 min-w-14 min-h-14 inline-flex items-center gap-x-2 text-sm rounded-lg whitespace-pre-wrap bg-gray-200 text-gray-900 bg-gray-200 text-gray-900 max-w-24 sm:max-w-32">
                            <div class="p-2 inline-flex justify-center items-center rounded-full bg-gray-300 text-gray-900 bg-gray-300 text-gray-900">
                              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="w-5 h-5">
                                <path fill-rule="evenodd" d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm2 6a1 1 0 011-1h6a1 1 0 110 2H7a1 1 0 01-1-1zm1 3a1 1 0 100 2h6a1 1 0 100-2H7z" clip-rule="evenodd"></path>
                              </svg>
                            </div>
                            <span class="truncate"><%= String.split(@path, "/") |> List.last() %></span>
                          </div>
                          <button type="button" phx-click="remove_pdf" class="p-1 absolute -top-2 -right-2 rounded-full bg-gray-100 hover:bg-gray-200 text-gray-500 border border-gray-300 shadow" title="Delete">
                            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="h-4 w-4 text-gray-700">
                              <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"></path>
                            </svg>
                          </button>
                        </div>
                      </div>
                      <div class="relative flex grow">
                        <input id="message" name="message" value={@text} class={"#{if !is_nil(@path), do: "border-transparent"} block w-full rounded-md border-gray-300 shadow-sm #{if is_nil(@path), do: "focus:border-indigo-500 focus:ring-indigo-500"} text-sm placeholder:text-gray-400 text-gray-900"} placeholder={if is_nil(@path), do: "drag pdf here to get started", else: "Ask a question..."} type="text" />
                      </div>
                    </div>
                    <div class="ml-1">
                        <button disabled={is_nil(@path)} type="submit" class={"flex items-center justify-center h-10 w-10 rounded-full #{if is_nil(@path), do: "cursor-not-allowed bg-gray-100 text-gray-300", else: "hover:bg-gray-300 bg-gray-200 text-gray-500"}"}>
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
