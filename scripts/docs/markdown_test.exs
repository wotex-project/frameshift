Code.require_file("markdown.exs", __DIR__)
ExUnit.start()

defmodule Frameshift.Documentation.MarkdownTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Documentation.Markdown

  setup do
    assert Markdown.available?()

    root =
      Path.join(System.tmp_dir!(), "frameshift-doc-links-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "apps/core"))
    File.write!(Path.join(root, "docs/README.md"), "# Documentation")
    File.write!(Path.join(root, "apps/core/README.md"), "# Core")
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      root: root,
      output: Path.join(root, "output"),
      route: "/docs/dev/",
      commit: String.duplicate("a", 40),
      source_url: "https://github.com/wotex-project/frameshift",
      pages: %{"docs/README.md" => "docs--readme", "apps/core/README.md" => "apps--core--readme"}
    }

    %{context: context, source: Path.join(root, "docs/README.md")}
  end

  test "same-basename links resolve by source path, preserving anchors and fenced examples", c do
    html =
      render(c, """
      [Index](README.md) [Core](../apps/core/README.md#storage)

      ```markdown
      [Example](../apps/core/README.md)
      ```
      """)

    assert html =~ ~s(href="/docs/dev/docs--readme.html")
    assert html =~ ~s(href="/docs/dev/apps--core--readme.html#storage")
    assert html =~ "[Example](../apps/core/README.md)"
  end

  test "repository heading anchors retain punctuation removal and duplicate identity", c do
    html = render(c, "## D-010 — Host metadata boundary\n\n## Same heading\n\n## Same heading\n")
    assert html =~ ~s(id="d-010--host-metadata-boundary")
    assert html =~ ~s(id="same-heading")
    assert html =~ ~s(id="same-heading-1")
  end

  test "code links bind the exact commit and embedded images are copied locally", c do
    File.write!(Path.join(c.context.root, "apps/core/sample.ex"), "fixture source")
    File.write!(Path.join(c.context.root, "docs/picture.svg"), "<svg/>")
    html = render(c, "[Source](../apps/core/sample.ex#L1) ![Fixture](picture.svg)")
    assert html =~ "/blob/#{c.context.commit}/apps/core/sample.ex#L1"
    # A bare image name is still a repository image and must be copied.
    assert html =~ ~s(src="/docs/dev/source-assets/docs/picture.svg")
    assert File.read!(Path.join(c.context.output, "source-assets/docs/picture.svg")) == "<svg/>"
  end

  test "missing, escaped and symlinked source links refuse without fetching", c do
    assert_raise RuntimeError, ~r/not a regular source file/, fn ->
      render(c, "[Missing](missing.md)")
    end

    assert_raise RuntimeError, ~r/escapes repository/, fn ->
      render(c, "[Escape](../../missing.md)")
    end

    File.ln_s!(
      Path.join(c.context.root, "apps/core/README.md"),
      Path.join(c.context.root, "docs/link.md")
    )

    assert_raise RuntimeError, ~r/not a regular source file/, fn ->
      render(c, "[Link](link.md)")
    end

    File.ln_s!(Path.join(c.context.root, "apps/core"), Path.join(c.context.root, "docs/alias"))

    assert_raise RuntimeError, ~r/unsafe documentation source directory/, fn ->
      render(c, "[Alias](alias/README.md)")
    end
  end

  defp render(context, text) do
    text
    |> Markdown.to_ast(file: context.source, frameshift: context.context)
    |> ExDoc.DocAST.to_html()
  end
end
