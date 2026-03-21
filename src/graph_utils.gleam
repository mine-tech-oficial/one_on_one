import graph.{type Context, type Graph}

pub fn fold(
  over graph: Graph(direction, value, label),
  from initial: acc,
  with fun: fn(acc, Context(value, label)) -> acc,
) -> acc {
  case graph.match_any(graph) {
    Ok(#(ctx, graph)) -> fold(graph, fun(initial, ctx), fun)
    Error(_) -> initial
  }
}
