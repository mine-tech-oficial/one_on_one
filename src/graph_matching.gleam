import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/set.{type Set}
import graph.{type Graph, type Node}
import graph_utils
import prng/random

type Matching =
  dict.Dict(Int, Int)

pub fn maximum_matching(
  graph: Graph(graph.Undirected, value, label),
  seed: random.Seed,
) -> #(
  List(#(Int, Int)),
  List(Int),
  Graph(graph.Undirected, value, label),
  random.Seed,
) {
  let #(nodes, seed) = random.step(random.shuffle(graph.nodes(graph)), seed)
  let edge_set = edge_set(graph)
  let matching =
    list.fold(nodes, dict.new(), fn(matching, node) {
      match_node(graph, matching, node)
    })
  let #(matching, remaining, graph) =
    list.fold(nodes, #([], [], graph), fn(acc, v) {
      case dict.get(matching, v.id) {
        Ok(w) if v.id <= w ->
          case set.contains(edge_set, #(v.id, w)) {
            True -> #(
              [#(v.id, w), ..acc.0],
              acc.1,
              graph.remove_undirected_edge(acc.2, v.id, w),
            )
            False -> #(
              [#(w, v.id), ..acc.0],
              acc.1,
              graph.remove_undirected_edge(acc.2, w, v.id),
            )
          }
        Ok(_) -> acc
        _ -> #(acc.0, [v.id, ..acc.1], acc.2)
      }
    })
  #(matching, remaining, graph, seed)
}

fn match_node(
  graph: Graph(direction, value, label),
  matching: Matching,
  node: Node(value),
) -> Matching {
  use <- bool.guard(dict.has_key(matching, node.id), matching)

  let #(parent, node) =
    do_match_node(
      graph,
      matching,
      node.id,
      list.map(graph.nodes(graph), fn(node) { node.id }),
      [node.id],
      set.from_list([node.id]),
      dict.new(),
      list.fold(graph.nodes(graph), dict.new(), fn(acc, node) {
        dict.insert(acc, node.id, node.id)
      }),
    )
  construct_matching(parent, matching, node)
}

fn construct_matching(
  parent: Matching,
  matching: Matching,
  node: Result(Int, Nil),
) -> Matching {
  case node {
    Error(Nil) -> matching
    Ok(node) -> {
      let assert Ok(node2) = dict.get(parent, node)
      construct_matching(
        parent,
        dict.insert(dict.insert(matching, node, node2), node2, node),
        dict.get(matching, node2),
      )
    }
  }
}

fn do_match_node(
  graph: Graph(direction, value, label),
  matching: Matching,
  root: Int,
  nodes: List(Int),
  queue: List(Int),
  used_nodes: Set(Int),
  parent: Matching,
  base: Matching,
) -> #(Matching, Result(Int, Nil)) {
  case queue {
    [] -> #(parent, Error(Nil))
    [node, ..rest] ->
      case graph.get_context(graph, node) {
        Ok(ctx) ->
          case
            list.try_fold(
              list.append(dict.keys(ctx.incoming), dict.keys(ctx.outgoing)),
              #(rest, used_nodes, parent, base),
              fn(acc, v) {
                let #(queue, used_nodes, parent, base) = acc
                go(
                  root,
                  matching,
                  node,
                  nodes,
                  queue,
                  used_nodes,
                  parent,
                  base,
                  v,
                )
              },
            )
          {
            Ok(#(queue, used_nodes, parent, base)) ->
              do_match_node(
                graph,
                matching,
                root,
                nodes,
                queue,
                used_nodes,
                parent,
                base,
              )
            Error(ret) -> ret
          }
        Error(_) ->
          do_match_node(
            graph,
            matching,
            root,
            nodes,
            rest,
            used_nodes,
            parent,
            base,
          )
      }
  }
}

fn go(
  root: Int,
  matching: Matching,
  node: Int,
  nodes: List(Int),
  queue: List(Int),
  used_nodes: Set(Int),
  parent: Matching,
  base: Matching,
  node2: Int,
) -> Result(
  #(List(Int), Set(Int), Matching, Matching),
  #(Matching, Result(Int, Nil)),
) {
  use <- bool.guard(
    dict.get(base, node) == dict.get(base, node2),
    Ok(#(queue, used_nodes, parent, base)),
  )
  use <- bool.guard(
    dict.get(matching, node) == Ok(node2),
    Ok(#(queue, used_nodes, parent, base)),
  )
  case
    node2 == root
    || result.unwrap(
      result.map(dict.get(matching, node2), dict.has_key(parent, _)),
      False,
    )
  {
    True -> {
      let cur_base = lca(matching:, base:, parent:, node:, node2:)
      let #(blossom, parent) =
        mark_path(
          matching:,
          base:,
          parent:,
          v: node,
          b: cur_base,
          c: node2,
          blossom: set.new(),
        )
      let #(blossom, parent) =
        mark_path(
          matching:,
          base:,
          parent:,
          v: node2,
          b: cur_base,
          c: node,
          blossom: blossom,
        )
      let xs =
        list.filter(nodes, fn(x) {
          result.unwrap(
            result.map(dict.get(base, x), set.contains(blossom, _)),
            False,
          )
        })
      let xs2 = list.filter(nodes, fn(x) { !set.contains(used_nodes, x) })
      Ok(#(
        list.append(xs2, queue),
        set.union(used_nodes, set.from_list(xs2)),
        parent,
        list.fold(xs, base, fn(acc, k) { dict.insert(acc, k, cur_base) }),
      ))
    }
    False ->
      case dict.has_key(parent, node2) {
        True -> Ok(#(queue, used_nodes, parent, base))
        False -> {
          let parent = dict.insert(parent, node2, node)
          case dict.get(matching, node2) {
            Ok(w) ->
              Ok(#([w, ..queue], set.insert(used_nodes, w), parent, base))
            Error(Nil) -> Error(#(parent, Ok(node2)))
          }
        }
      }
  }
}

fn lca(
  matching matching: Matching,
  base base: Matching,
  parent parent: Matching,
  node node: Int,
  node2 node2: Int,
) -> Int {
  let seen = get_seen(matching, base, parent, set.new(), node)
  do_lca(matching, base, parent, seen, node2)
}

fn do_lca(
  matching: dict.Dict(Int, Int),
  base: dict.Dict(Int, Int),
  parent: dict.Dict(Int, Int),
  seen: Set(Int),
  node: Int,
) -> Int {
  let assert Ok(node) = dict.get(base, node)
  case set.contains(seen, node) {
    True -> node
    False -> {
      let assert Ok(node) = dict.get(matching, node)
      let assert Ok(node) = dict.get(parent, node)
      do_lca(matching, base, parent, seen, node)
    }
  }
}

fn get_seen(
  matching: Matching,
  base: Matching,
  parent: Matching,
  seen: Set(Int),
  node: Int,
) -> Set(Int) {
  let assert Ok(node) = dict.get(base, node)
  let seen = set.insert(seen, node)
  case dict.get(matching, node) {
    Ok(node) -> {
      let assert Ok(node) = dict.get(parent, node)
      get_seen(matching, base, parent, seen, node)
    }
    Error(Nil) -> seen
  }
}

fn mark_path(
  matching matching: Matching,
  base base: Matching,
  parent parent: Matching,
  v v: Int,
  b b: Int,
  c c: Int,
  blossom blossom: Set(Int),
) -> #(Set(Int), Matching) {
  use <- bool.guard(dict.get(base, v) == Ok(b), #(blossom, parent))
  let assert Ok(w) = dict.get(matching, v)
  let assert Ok(bv) = dict.get(base, v)
  let assert Ok(bw) = dict.get(base, w)
  let parent = dict.insert(parent, v, c)
  let assert Ok(v) = dict.get(parent, w)
  mark_path(
    matching:,
    base:,
    parent:,
    v:,
    b:,
    c: w,
    blossom: set.insert(set.insert(blossom, bv), bw),
  )
}

fn edge_set(graph: Graph(direction, value, label)) -> Set(#(Int, Int)) {
  graph_utils.fold(graph, set.new(), fn(acc, ctx) {
    acc
    |> dict.fold(ctx.incoming, _, fn(acc, id, _) {
      set.insert(acc, #(ctx.node.id, id))
    })
    |> dict.fold(ctx.outgoing, _, fn(acc, id, _) {
      set.insert(acc, #(id, ctx.node.id))
    })
  })
}
