defmodule Frameshift.Documentation.Markdown do
  @moduledoc """
  Resolves repository links before ExDoc renders the maintained documentation.

  The locked ExDoc Earmark adapter remains the Markdown parser and renderer.
  This adapter rewrites only parsed link/image attributes, using each original
  source file and the selected page inventory. Distinct component READMEs have
  distinct output identities; basename matching cannot send a reader to another
  component. Module/function references remain owned by ExDoc's API autolinker.

  ## Source custody

  Local Markdown links name generated pages or exact-commit source files.
  Embedded repository images are copied into the same offline documentation
  directory after regular-file and size checks. Missing files, traversal outside
  the repository and symlinks refuse the build. The adapter does not fetch remote
  content, mutate maintained Markdown or decide release/publication authority.
  """

  @behaviour ExDoc.Markdown

  @impl true
  def available?, do: ExDoc.Markdown.Earmark.available?()

  @impl true
  def to_ast(text, options) do
    context = Keyword.fetch!(options, :frameshift)
    source = Path.expand(Keyword.fetch!(options, :file))

    ast =
      text
      |> ExDoc.Markdown.Earmark.to_ast(Keyword.delete(options, :frameshift))
      |> rewrite(source, context)

    if Map.has_key?(context.pages, Path.relative_to(source, context.root)),
      do: repository_headers(ast),
      else: ast
  end

  defp repository_headers(ast) do
    ast
    |> ExDoc.DocAST.map_reduce_tags(%{}, fn {tag, attrs, inner, meta} = node, seen ->
      if tag in [:h2, :h3, :h4, :h5, :h6] and not Keyword.has_key?(attrs, :id) do
        slug =
          inner
          |> ExDoc.DocAST.text()
          |> String.downcase()
          |> String.replace(~r/[^\p{L}\p{M}\p{N}\s_-]/u, "")
          |> String.replace(~r/\s/u, "-")

        count = Map.get(seen, slug, 0)
        id = if count == 0, do: slug, else: "#{slug}-#{count}"
        {{tag, [id: id] ++ attrs, inner, meta}, Map.put(seen, slug, count + 1)}
      else
        {node, seen}
      end
    end)
    |> elem(0)
  end

  defp rewrite(nodes, source, context) when is_list(nodes),
    do: Enum.map(nodes, &rewrite(&1, source, context))

  defp rewrite({tag, attributes, children, metadata}, source, context) do
    attributes =
      Enum.map(attributes, fn
        {:href, link} when tag == :a -> {:href, resolve(link, source, context, false)}
        {:src, link} when tag == :img -> {:src, resolve(link, source, context, true)}
        attribute -> attribute
      end)

    {tag, attributes, rewrite(children, source, context), metadata}
  end

  defp rewrite(other, _, _), do: other

  defp resolve(link, source, context, image?) do
    uri = URI.parse(link)

    if repository_link?(uri, link) or local_image?(uri, image?) do
      path = uri.path |> URI.decode() |> Path.expand(Path.dirname(source))
      relative = Path.relative_to(path, context.root)
      validate_file!(path, relative)
      validate_directories!(context.root, relative)
      resolve_file(uri, path, relative, context, image?)
    else
      link
    end
  end

  defp validate_directories!(root, relative) do
    relative
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce(root, fn component, directory ->
      next = Path.join(directory, component)

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> next
        _ -> raise "unsafe documentation source directory: #{relative}"
      end
    end)
  end

  defp repository_link?(%URI{scheme: nil, host: nil, path: path}, link)
       when is_binary(path) and path != "" do
    not String.starts_with?(link, ["/", "`", "#"]) and
      (String.contains?(path, "/") or Path.extname(path) == ".md")
  end

  defp repository_link?(_, _), do: false

  defp local_image?(%URI{scheme: nil, host: nil, path: path}, true)
       when is_binary(path) and path != "",
       do: not String.starts_with?(path, "/")

  defp local_image?(_, _), do: false

  defp validate_file!(path, relative) do
    if Path.type(relative) != :relative or relative == ".." or
         String.starts_with?(relative, "../"),
       do: raise("documentation link escapes repository: #{relative}")

    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      _ -> raise "documentation link is not a regular source file: #{relative}"
    end
  end

  defp resolve_file(uri, path, relative, context, true) do
    if File.stat!(path).size > 25 * 1024 * 1024,
      do: raise("oversized documentation image: #{relative}")

    destination = Path.join([context.output, "source-assets", relative])
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(path, destination)
    %{uri | path: context.route <> "source-assets/" <> encode_path(relative)} |> URI.to_string()
  end

  defp resolve_file(uri, _, relative, context, false) do
    case context.pages[relative] do
      nil ->
        context.source_url <>
          "/blob/" <>
          context.commit <>
          "/" <>
          encode_path(relative) <>
          fragment(uri.fragment)

      page ->
        %{uri | path: context.route <> page <> ".html"} |> URI.to_string()
    end
  end

  defp encode_path(path), do: URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))
  defp fragment(nil), do: ""
  defp fragment(value), do: "#" <> value
end
