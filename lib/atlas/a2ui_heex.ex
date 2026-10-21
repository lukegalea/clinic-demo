defmodule Atlas.A2uiHeex do
  @moduledoc """
  SPIKE: a server-side HEEx renderer for A2UI messages, read-only subset.

  Renders the same `createSurface` / `updateComponents` / `updateDataModel`
  messages ash_a2ui sends the Lit catalog, but on the server, with Atlas
  classes, so a declared screen is in the first HTML response.

  Read-only: the interactive types (`Button`, `CheckBox`, `TextField`,
  `Modal`, `pagination`, pickers) are skipped, and so are the query-control
  cards that only hold them. `stats/1` counts what was rendered and skipped.

  Not a production renderer: bindings, List templates and visibility are the
  minimum the contract surface uses (absolute and row-relative paths, the
  `_empty_visible_<table>` convention for empty states).
  """

  use Phoenix.Component

  @interactive ~w(Button CheckBox TextField Modal pagination ChoicePicker DateTimeInput Slider)

  @doc "The component map, data model and root of a surface's messages."
  def parse(messages) do
    components =
      for message <- messages,
          component <- get_in(message, ["updateComponents", "components"]) || [],
          into: %{},
          do: {component["id"], component}

    data = Enum.find_value(messages, %{}, &get_in(&1, ["updateDataModel", "value"]))
    %{components: components, data: data}
  end

  @doc "Component types in the surface: rendered here vs skipped (interactive)."
  def stats(%{components: components}) do
    {skipped, rendered} =
      components |> Map.values() |> Enum.split_with(&(&1["component"] in @interactive))

    %{
      total: map_size(components),
      rendered: length(rendered),
      skipped: length(skipped),
      skipped_types: skipped |> Enum.map(& &1["component"]) |> Enum.frequencies()
    }
  end

  attr :surface, :map, required: true, doc: "the result of parse/1"

  attr :title, :boolean,
    default: false,
    doc: "render the entityPage title (a HEEx shell usually owns it)"

  def surface(assigns) do
    ~H"""
    <div data-a2ui-heex class="flex flex-col gap-6 font-sans text-(--atlas-text-primary)">
      <.component
        :if={@surface.components["root"]}
        c={@surface.components["root"]}
        ctx={Map.put(@surface, :title, @title)}
        scope=""
      />
    </div>
    """
  end

  attr :c, :map, required: true
  attr :ctx, :map, required: true
  attr :scope, :string, required: true

  defp component(%{c: %{"component" => "entityPage"}} = assigns) do
    ~H"""
    <h1 :if={@ctx.title} class="text-2xl font-semibold">{@c["title"]}</h1>
    <.children ids={@c["children"]} ctx={@ctx} scope={@scope} />
    """
  end

  defp component(%{c: %{"component" => "Text"}} = assigns) do
    assigns = assign(assigns, text: value(assigns.c["text"], assigns.ctx, assigns.scope))

    ~H"""
    <%= case @c["variant"] do %>
      <% "h1" -> %>
        <h2 :if={present?(@text)} class="text-xl font-semibold">{@text}</h2>
      <% "h2" -> %>
        <h2 :if={present?(@text)} class="text-lg font-semibold mt-2">{@text}</h2>
      <% v when v in ["h3", "h4", "h5"] -> %>
        <h3 :if={present?(@text)} class="font-semibold">{@text}</h3>
      <% "caption" -> %>
        <p :if={present?(@text)} class="text-xs text-(--atlas-text-tertiary)">{@text}</p>
      <% _ -> %>
        <span :if={present?(@text)} class="text-sm">{@text}</span>
    <% end %>
    """
  end

  defp component(%{c: %{"component" => "Row"}} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <.children ids={@c["children"]} ctx={@ctx} scope={@scope} />
    </div>
    """
  end

  defp component(%{c: %{"component" => "Column"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.children ids={@c["children"]} ctx={@ctx} scope={@scope} />
    </div>
    """
  end

  # Query-control cards hold only interactive controls: nothing to show read-only.
  defp component(%{c: %{"component" => "Card", "id" => "query_" <> _}} = assigns), do: ~H""

  defp component(%{c: %{"component" => "Card"}} = assigns) do
    ~H"""
    <div class="rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface) p-4">
      <.children ids={List.wrap(@c["child"])} ctx={@ctx} scope={@scope} />
    </div>
    """
  end

  # A List is either fixed children or a template repeated per row at a path.
  defp component(
         %{c: %{"component" => "List", "children" => %{"componentId" => id, "path" => path}}} =
           assigns
       ) do
    assigns =
      assign(assigns,
        template: assigns.ctx.components[id],
        base: absolute(path, assigns.scope),
        items: List.wrap(value(%{"path" => path}, assigns.ctx, assigns.scope))
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <.component
        :for={{_item, index} <- Enum.with_index(@items)}
        :if={@template}
        c={@template}
        ctx={@ctx}
        scope={"#{@base}/#{index}"}
      />
    </div>
    """
  end

  defp component(%{c: %{"component" => "List"}} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.children ids={List.wrap(@c["children"])} ctx={@ctx} scope={@scope} />
    </div>
    """
  end

  defp component(%{c: %{"component" => "fieldDisplay"}} = assigns) do
    assigns = assign(assigns, value: value(assigns.c["value"], assigns.ctx, assigns.scope))

    ~H"""
    <div class="grid grid-cols-[minmax(8rem,1fr)_2fr] gap-4 py-2 border-b border-(--atlas-border-subtle) text-sm">
      <dt class="font-medium text-(--atlas-text-secondary)">{@c["label"]}</dt>
      <dd>{display(@value)}</dd>
    </div>
    """
  end

  defp component(%{c: %{"component" => "dataGrid"}} = assigns) do
    assigns =
      assign(assigns, rows: List.wrap(value(assigns.c["rows"], assigns.ctx, assigns.scope)))

    ~H"""
    <div class="rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface) overflow-x-auto">
      <table class="w-full text-sm">
        <caption :if={@c["label"]} class="sr-only">{@c["label"]}</caption>
        <thead class="bg-(--atlas-bg-surface-sunken) text-left">
          <tr>
            <th :for={col <- @c["columns"]} scope="col" class="px-3 py-2 font-medium">
              {col["label"]}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-t border-(--atlas-border-default)">
            <td :for={col <- @c["columns"]} class="px-3 py-2">
              {display(get_in(row, [col["path"]]))}
            </td>
          </tr>
        </tbody>
      </table>
      <.children :if={@rows == []} ids={@c["children"]} ctx={@ctx} scope={@scope} />
    </div>
    """
  end

  defp component(%{c: %{"component" => "emptyState", "id" => "empty_state_" <> table}} = assigns) do
    assigns =
      assign(assigns,
        visible: assigns.ctx.data["_empty_visible_#{table}"] == true,
        message: value(assigns.c["message"], assigns.ctx, assigns.scope)
      )

    ~H"""
    <p :if={@visible} class="px-3 py-4 text-sm text-(--atlas-text-secondary)">{@message}</p>
    """
  end

  defp component(%{c: %{"component" => "statusBanner"}} = assigns) do
    assigns = assign(assigns, message: value(assigns.c["message"], assigns.ctx, assigns.scope))

    ~H"""
    <p :if={present?(@message)} role="status" class="text-sm">{@message}</p>
    """
  end

  # Interactive and unknown types: not rendered read-only.
  defp component(assigns), do: ~H""

  attr :ids, :list, default: []
  attr :ctx, :map, required: true
  attr :scope, :string, required: true

  defp children(assigns) do
    ~H"""
    <.component
      :for={id <- List.wrap(@ids)}
      :if={@ctx.components[id]}
      c={@ctx.components[id]}
      ctx={@ctx}
      scope={@scope}
    />
    """
  end

  # Bindings: a literal, an absolute path ("/detail/contract/name") or a path
  # relative to the current List row ("label").
  defp value(%{"path" => path}, ctx, scope), do: fetch(ctx.data, absolute(path, scope))
  defp value(literal, _ctx, _scope), do: literal

  defp absolute("/" <> _ = path, _scope), do: path
  defp absolute(path, scope), do: "#{scope}/#{path}"

  defp fetch(data, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce_while(data, fn
      segment, list when is_list(list) ->
        case Integer.parse(segment) do
          {index, ""} -> {:cont, Enum.at(list, index)}
          _ -> {:halt, nil}
        end

      segment, map when is_map(map) ->
        {:cont, Map.get(map, segment)}

      _segment, _other ->
        {:halt, nil}
    end)
  end

  defp present?(value), do: value not in [nil, ""]

  # Dates are read where they are: a date-only value has no time zone.
  defp display(nil), do: "—"
  defp display(""), do: "—"

  defp display(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d, %Y")
      _ -> value
    end
  end

  defp display(true), do: "Yes"
  defp display(false), do: "No"
  defp display(value), do: to_string(value)
end
