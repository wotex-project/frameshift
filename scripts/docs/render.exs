Code.require_file("markdown.exs", __DIR__)

defmodule Frameshift.Documentation.Render do
  @moduledoc """
  Builds source-bound Markdown and core API pages with the locked ExDoc toolchain.

  `run/1` consumes the local build coordinator's bounded source/page inventory.
  Original Markdown stays beside its owner; unique repository-path page IDs and
  a parsed link resolver join the specification corpus and component READMEs to
  the native core API. ExDoc owns formatting, API anchors and search assets.

  ## Evidence boundary

  Every page names its versioned documentation, unreleased development or dirty
  preview identity and selected source commit. Versioned input must match the
  actual application version. The coordinator owns exact tag/source checks,
  input digests, immutable version inventories and publication eligibility.
  Rendering does not grant installer, physical-profile or public-site authority.
  ExDoc warnings refuse the build rather than hiding missing reference evidence.
  """

  @spec run(String.t()) :: :ok
  def run(input_path) do
    {:ok, _} = Application.ensure_all_started(:ex_doc)
    input = input_path |> File.read!() |> Jason.decode!()
    root = input["root"]
    output = input["output"]
    commit = input["commit"]
    source_url = "https://github.com/wotex-project/frameshift"
    pages = Map.new(input["pages"], &{&1["source"], &1["id"]})
    release? = input["channel"] == "release-documentation"
    version = if release?, do: input["version"], else: "0.1.0-dev (unreleased)"

    if release? and Mix.Project.config()[:version] != version,
      do: raise("release documentation version differs from the application")

    label =
      cond do
        release? -> "Versioned documentation #{version}"
        input["preview"] -> "Unreleased preview"
        true -> "Unreleased development"
      end

    route = input["route"] || "/docs/dev/"

    context = %{
      root: root,
      output: output,
      commit: commit,
      source_url: source_url,
      pages: pages,
      route: route
    }

    extras =
      Enum.map(input["pages"], fn page ->
        {Path.join(root, page["source"]), [filename: page["id"]]}
      end)

    source_link = fn path, line ->
      relative = path |> Path.expand() |> Path.relative_to(root)

      if Path.type(relative) != :relative or String.starts_with?(relative, "../"),
        do: raise("API source metadata escapes the selected repository")

      source_url <> "/blob/" <> commit <> "/" <> relative <> "#L#{line}"
    end

    results =
      ExDoc.generate("Frameshift · #{label}", version, [Mix.Project.compile_path()],
        output: output,
        extras: extras,
        main: pages["docs/README.md"],
        formatters: ["html"],
        homepage_url: "/",
        source_url_pattern: source_link,
        canonical: "https://frameshift.wotex.io" <> String.trim_trailing(route, "/"),
        markdown_processor: {Frameshift.Documentation.Markdown, frameshift: context},
        before_closing_footer_tag: fn :html ->
          "<p><strong>#{label}</strong> · source <code>#{commit}</code>. " <>
            "<a href=\"/docs/\">Release status</a> · <a href=\"/download/\">Downloads</a></p>"
        end
      )

    if Enum.any?(results, & &1.warned?), do: raise("documentation rendering emitted warnings")

    :ok
  end
end

case System.argv() do
  [input] -> Frameshift.Documentation.Render.run(input)
  _ -> raise "usage: mix run --no-start scripts/docs/render.exs INPUT"
end
