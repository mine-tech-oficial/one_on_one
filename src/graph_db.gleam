import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import graph
import graph_utils
import simplifile

pub fn load_graph(
  path: String,
) -> Result(graph.Graph(graph.Undirected, Nil, Nil), simplifile.FileError) {
  use file_contents <- result.map(simplifile.read(path))
  file_contents
  |> string.split(on: "\n")
  |> list.fold(graph.new(), fn(acc, line) {
    case string.split_once(line, ",") {
      Ok(#(a, b)) ->
        case int.parse(a), int.parse(b) {
          Ok(a), Ok(b) -> graph.insert_undirected_edge(acc, Nil, a, b)
          _, _ -> acc
        }
      Error(_) ->
        case int.parse(line) {
          Ok(id) -> graph.insert_node(acc, graph.Node(id, Nil))
          _ -> acc
        }
    }
  })
}

pub fn save_graph(
  graph: graph.Graph(direction, value, label),
  path: String,
  tmp_path: String,
) -> Result(Nil, simplifile.FileError) {
  list.fold(graph.nodes(graph), "", fn(acc, node) {
    acc <> int.to_string(node.id) <> "\n"
  })
  |> graph_utils.fold(graph, _, fn(acc, ctx) {
    dict.fold(ctx.outgoing, acc, fn(acc, node, _) {
      acc <> int.to_string(ctx.node.id) <> "," <> int.to_string(node) <> "\n"
    })
  })
  |> simplifile.write(to: tmp_path)
  |> result.try(fn(_) { simplifile.rename(tmp_path, path) })
}
