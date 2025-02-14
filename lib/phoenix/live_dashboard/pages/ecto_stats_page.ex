defmodule Phoenix.LiveDashboard.EctoStatsPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder
  import Phoenix.LiveDashboard.Helpers

  @compile {:no_warn_undefined, [Decimal, EctoPSQLExtras, {Ecto.Repo, :all_running, 0}]}
  @disabled_link "https://hexdocs.pm/phoenix_live_dashboard/ecto_stats.html"
  @page_title "Ecto Stats"

  @impl true
  def init(%{repos: repos, ecto_psql_extras_options: ecto_options}) do
    capabilities = for repo <- List.wrap(repos), do: {:process, repo}
    repos = repos || :auto_discover

    {:ok, %{repos: repos, ecto_options: ecto_options}, capabilities}
  end

  @impl true
  def mount(_params, %{repos: repos, ecto_options: ecto_options}, socket) do
    socket = assign(socket, ecto_options: ecto_options)

    result =
      case repos do
        :auto_discover ->
          auto_discover()

        [_ | _] = repos ->
          {:ok, repos}

        _ ->
          {:error, :no_ecto_repos_available}
      end

    case result do
      {:ok, repos} ->
        {:ok, assign(socket, :repos, repos)}

      {:error, error} ->
        {:ok, assign(socket, :error, error)}
    end
  end

  defp auto_discover do
    case named_stats_available_repos() do
      [_ | _] = repos ->
        {:ok, repos}

      [] ->
        {:error, :no_ecto_repos_available}
    end
  end

  defp named_stats_available_repos do
    Enum.filter(Ecto.Repo.all_running(), &extra_available?/1)
  end

  @impl true
  def menu_link(%{repos: []}, _capabilities) do
    :skip
  end

  @impl true
  def menu_link(%{repos: :auto_discover}, _caps) do
    {:ok, @page_title}
  end

  @impl true
  def menu_link(%{repos: repos}, capabilities) do
    cond do
      Enum.all?(repos, fn repo -> repo not in capabilities.processes end) ->
        :skip

      extra_available_for_any?(repos) ->
        {:ok, @page_title}

      true ->
        {:disabled, @page_title, @disabled_link}
    end
  end

  defp extra_available_for_any?(repos) do
    Enum.any?(repos, &extra_available?/1)
  end

  defp extra_available?(repo) when is_atom(repo) do
    extra = info_module_for(repo)
    extra && Code.ensure_loaded?(extra)
  end

  defp extra_available?(_repo_pid), do: false

  defp info_module_for(repo) do
    case repo.__adapter__ do
      Ecto.Adapters.Postgres -> EctoPSQLExtras
      _ -> nil
    end
  end

  @impl true
  def render_page(assigns) do
    if assigns[:error] do
      render_error(assigns)
    else
      items =
        for repo <- assigns.repos do
          info_module = info_module_for(repo)

          {repo,
           name: inspect(repo),
           render: fn ->
             render_repo_tab(%{
               repo: repo,
               info_module: info_module,
               ecto_options: assigns.ecto_options
             })
           end}
        end

      nav_bar(items: items, nav_param: :repo, extra_params: [:nav], style: :bar)
    end
  end

  defp render_repo_tab(assigns) do
    nav_bar(items: items(assigns), extra_params: [:repo])
  end

  @forbidden_tables [:kill_all, :mandelbrot]

  defp items(%{repo: repo, info_module: info_module, ecto_options: ecto_options}) do
    for {table_name, table_module} <- info_module.queries(repo),
        table_name not in @forbidden_tables do
      {table_name,
       name: Phoenix.Naming.humanize(table_name),
       render: fn ->
         render_table(repo, info_module, table_name, table_module, ecto_options)
       end}
    end
  end

  defp render_table(repo, info_module, table_name, table_module, ecto_options) do
    info = table_module.info()

    columns =
      for %{name: name, type: type} <- info.columns do
        %{field: name, sortable: sortable(type), format: &format(type, &1)}
      end

    searchable = for %{type: :string, name: name} <- info.columns, do: name
    default_sort_by = with [{column, _} | _] <- info[:order_by], do: column

    table(
      id: :table_id,
      hint: info.title,
      limit: false,
      default_sort_by: default_sort_by,
      search: searchable != [],
      columns: columns,
      rows_name: "entries",
      row_fetcher: &row_fetcher(repo, info_module, table_name, searchable, ecto_options, &1, &2),
      title: Phoenix.Naming.humanize(table_name)
    )
  end

  defp sortable(:string), do: :asc
  defp sortable(_), do: :desc

  defp row_fetcher(repo, info_module, table_name, searchable, ecto_options, params, _node) do
    opts =
      case Keyword.fetch(ecto_options, table_name) do
        {:ok, args} -> [args: args]
        :error -> []
      end
      |> Keyword.merge(format: :raw)

    %{columns: columns, rows: rows} = info_module.query(table_name, repo, opts)

    mapped =
      for row <- rows do
        columns
        |> Enum.zip(row)
        |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
      end

    %{search: search, sort_by: sort_by, sort_dir: sort_dir} = params

    mapped =
      if search do
        Enum.filter(mapped, fn map ->
          Enum.any?(searchable, fn column ->
            value = Map.fetch!(map, column)
            value && value =~ search
          end)
        end)
      else
        mapped
      end

    sorted =
      Enum.sort_by(mapped, &Map.fetch!(&1, sort_by), fn
        # Handle structs
        %struct{} = left, %struct{} = right ->
          case struct.compare(left, right) do
            :gt when sort_dir == :asc -> false
            :lt when sort_dir == :desc -> false
            _ -> true
          end

        # Nils are always last regardless of ordering
        nil, _ ->
          false

        _, nil ->
          true

        # Handle all other types
        left, right when sort_dir == :asc ->
          left <= right

        left, right when sort_dir == :desc ->
          left >= right
      end)

    {sorted, length(rows)}
  end

  defp format(_, %struct{} = value) when struct in [Decimal, Postgrex.Interval],
    do: struct.to_string(value)

  defp format(:bytes, value) when is_integer(value),
    do: format_bytes(value)

  defp format(:percent, value) when is_number(value),
    do: value |> Kernel.*(100.0) |> Float.round(1) |> Float.to_string()

  defp format(_type, value),
    do: value

  defp render_error(assigns) do
    error_message =
      case assigns.error do
        :no_ecto_repos_available ->
          error_details = """
          No Ecto repository was found or Ecto PSQL Extras is not installed.
          Currently only PSQL databases are supported.

          Check the <a href="https://hexdocs.pm/phoenix_live_dashboard/ecto_stats.html" target="_blank">documentation</a> for details.
          """

          {:safe, error_details}
      end

    row(
      components: [
        columns(
          components: [
            card(value: error_message)
          ]
        )
      ]
    )
  end
end
