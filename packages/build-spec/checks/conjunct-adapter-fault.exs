[source, beams, diagnostics] = System.argv()
File.mkdir!(beams)
actual = Kernel.ParallelCompiler.compile_to_path([source], beams, return_diagnostics: true)
File.write!(diagnostics, :erlang.term_to_binary(actual), [:exclusive])
{:ok, [_module], %{compile_warnings: [], runtime_warnings: []}} = actual
