import clockwork
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import graph
import graph_db
import graph_matching
import graph_utils
import grom
import grom/message
import prng/random

pub type PairementMsg {
  SetChannelId(channel_id: String)
  GetNextPairement(reply_to: process.Subject(timestamp.Timestamp))
  SimulatePairement(reply_to: process.Subject(String))
  RunPairementMsg(reply_to: process.Subject(String))
  RunPairement
}

pub type State {
  State(
    has_already_happened: Bool,
    seed: random.Seed,
    channel_id: String,
    self: process.Subject(PairementMsg),
  )
}

pub fn new(
  client: grom.Client,
  cron: clockwork.Cron,
  channel_id: String,
  graph_db_path: String,
  graph_temp_path: String,
) -> actor.Builder(State, PairementMsg, process.Subject(PairementMsg)) {
  actor.new_with_initialiser(1000, fn(self) {
    Ok(
      actor.initialised(State(
        has_already_happened: False,
        seed: random.new_seed(
          timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time()).0,
        ),
        channel_id:,
        self:,
      ))
      |> actor.returning(self),
    )
  })
  |> actor.on_message(fn(state, msg) {
    let State(has_already_happened:, seed:, channel_id:, self:) = state
    let next_occurrence = case has_already_happened {
      False ->
        clockwork.next_occurrence(
          given: cron,
          from: timestamp.system_time(),
          with_offset: duration.hours(-3),
        )

      True ->
        clockwork.next_occurrence(
          given: cron,
          from: timestamp.system_time(),
          with_offset: duration.hours(-3),
        )
        |> clockwork.next_occurrence(
          given: cron,
          from: _,
          with_offset: duration.hours(-3),
        )
    }
    case msg {
      SetChannelId(channel_id) -> actor.continue(State(..state, channel_id:))
      GetNextPairement(reply_to:) -> {
        process.send(reply_to, next_occurrence)
        actor.continue(state)
      }
      SimulatePairement(reply_to:) -> {
        let _ =
          result.map(graph_db.load_graph(graph_db_path), fn(graph) {
            let #(msg, _, _) = get_pairing(graph, seed)
            process.send(reply_to, msg)
          })
        actor.continue(state)
      }
      RunPairementMsg(reply_to:) -> {
        let assert Ok(seed) = {
          use graph <- result.try(graph_db.load_graph(graph_db_path))
          let #(msg, graph, seed) = get_pairing(graph, seed)
          let _ = graph_db.save_graph(graph, graph_db_path, graph_temp_path)
          process.send(reply_to, msg)
          Ok(seed)
        }
        actor.continue(State(
          has_already_happened: True,
          seed:,
          channel_id:,
          self:,
        ))
      }
      RunPairement -> {
        let assert Ok(seed) = case has_already_happened {
          False -> {
            use graph <- result.try(graph_db.load_graph(graph_db_path))
            let #(msg, graph, seed) = get_pairing(graph, seed)
            let _ = graph_db.save_graph(graph, graph_db_path, graph_temp_path)
            let _ =
              message.create(
                client,
                in: channel_id,
                using: message.Create(
                  ..message.new_create(),
                  content: Some(msg),
                ),
              )
            Ok(seed)
          }
          True -> Ok(seed)
        }
        process.send_after(
          self,
          duration.to_milliseconds(timestamp.difference(
            clockwork.next_occurrence(
              given: cron,
              from: timestamp.system_time(),
              with_offset: duration.hours(-3),
            ),
            timestamp.system_time(),
          )),
          RunPairement,
        )
        actor.continue(State(
          has_already_happened: !has_already_happened,
          seed:,
          channel_id:,
          self:,
        ))
      }
    }
  })
}

fn get_pairing(
  graph: graph.Graph(graph.Undirected, value, Nil),
  seed: random.Seed,
) -> #(String, graph.Graph(graph.Undirected, value, Nil), random.Seed) {
  let #(matching, remaining, graph, seed) =
    graph_matching.maximum_matching(graph, seed)
  let students_count = list.length(graph.nodes(graph))
  let #(matching, trio, graph, seed) = case remaining {
    [] -> #(matching, Error(Nil), graph, seed)
    [remaining] if students_count % 2 == 1 ->
      case matching {
        [] -> #([], Error(Nil), graph, seed)
        [first, ..rest] -> #(
          rest,
          Ok(#(first.0, first.1, remaining)),
          graph
            |> graph.remove_undirected_edge(first.0, remaining)
            |> graph.remove_undirected_edge(first.1, remaining),
          seed,
        )
      }
    _ -> {
      let #(matching, remaining, graph, seed) =
        graph_utils.fold(graph, graph.new(), fn(acc, ctx) {
          list.fold(
            graph.nodes(acc),
            graph.insert_node(acc, ctx.node),
            fn(acc, node) {
              graph.insert_undirected_edge(acc, Nil, ctx.node.id, node.id)
            },
          )
        })
        |> graph_matching.maximum_matching(seed)
      case remaining {
        [] -> #(matching, Error(Nil), graph, seed)
        [remaining, ..] ->
          case matching {
            [] -> #([], Error(Nil), graph, seed)
            [first, ..rest] -> #(
              rest,
              Ok(#(first.0, first.1, remaining)),
              graph
                |> graph.remove_undirected_edge(first.0, remaining)
                |> graph.remove_undirected_edge(first.1, remaining),
              seed,
            )
          }
      }
    }
  }
  let msg =
    list.index_fold(matching, "", fn(acc, pair, idx) {
      acc
      <> "**Par "
      <> int.to_string(idx + 1)
      <> ":** <@"
      <> int.to_string(pair.0)
      <> ">:left_right_arrow:<@"
      <> int.to_string(pair.1)
      <> ">\n"
    })
  let msg = case trio {
    Ok(trio) ->
      msg
      <> "**Trio:** <@"
      <> int.to_string(trio.0)
      <> ">:left_right_arrow:<@"
      <> int.to_string(trio.1)
      <> ">:left_right_arrow:<@"
      <> int.to_string(trio.2)
      <> ">\n"
    Error(Nil) -> msg
  }
  let msg = case msg {
    "" -> "Nenhum grupo formado\n"
    msg -> msg
  }
  #(msg, graph, seed)
}
