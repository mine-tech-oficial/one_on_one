import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import graph
import graph_utils
import simplifile

pub type UserData {
  UserData(username: String)
}

pub type LoadError {
  FileError(simplifile.FileError)
  InvalidFile
}

pub fn load_graph(
  path: String,
) -> Result(graph.Graph(graph.Undirected, UserData, Nil), LoadError) {
  use file_contents <- result.try(
    simplifile.read(path) |> result.map_error(FileError),
  )
  use #(nodes, edges) <- result.map(
    string.split_once(file_contents, on: "\n\n")
    |> result.replace_error(InvalidFile),
  )

  let graph =
    nodes
    |> string.split(on: "\n")
    |> list.fold(graph.new(), fn(acc, line) {
      case string.split(line, ",") {
        [id, username] ->
          case int.parse(id) {
            Ok(id) ->
              graph.insert_node(acc, graph.Node(id, UserData(username:)))
            _ -> acc
          }
        _ -> acc
      }
    })

  edges
  |> string.split(on: "\n")
  |> list.fold(graph, fn(acc, line) {
    case string.split_once(line, ",") {
      Ok(#(a, b)) ->
        case int.parse(a), int.parse(b) {
          Ok(a), Ok(b) -> graph.insert_undirected_edge(acc, Nil, a, b)
          _, _ -> acc
        }
      Error(_) -> acc
    }
  })
}

pub fn save_graph(
  graph: graph.Graph(direction, UserData, Nil),
  path: String,
  tmp_path: String,
) -> Result(Nil, simplifile.FileError) {
  let nodes =
    list.fold(graph.nodes(graph), "", fn(acc, node) {
      acc <> int.to_string(node.id) <> "," <> node.value.username <> "\n"
    })

  graph_utils.fold(graph, nodes <> "\n", fn(acc, ctx) {
    dict.fold(ctx.outgoing, acc, fn(acc, node, _) {
      acc <> int.to_string(ctx.node.id) <> "," <> int.to_string(node) <> "\n"
    })
  })
  |> simplifile.write(to: tmp_path)
  |> result.try(fn(_) { simplifile.rename(tmp_path, path) })
}
