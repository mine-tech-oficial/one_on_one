import gleam/http
import gleam/int
import gleam/list
import graph
import graph_db
import lustre/attribute
import lustre/element
import lustre/element/html
import wisp

pub fn handle_request(
  req: wisp.Request,
  graph_db_path: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)

  case echo graph_db.load_graph(graph_db_path) {
    Error(_) -> wisp.internal_server_error()
    Ok(graph) ->
      html.html([attribute.lang("pt")], [
        html.head([], [
          html.meta([attribute.charset("utf-8")]),
        ]),
        html.body([], [
          html.table([], [
            html.thead([], [
              html.tr([], [
                html.th([], [html.text("Nome de Usuário")]),
                html.td([], [html.text("ID do Discord")]),
              ]),
            ]),
            html.tbody(
              [],
              list.fold(graph.nodes(graph), [], fn(acc, node) {
                [
                  html.tr([], [
                    html.th([], [html.text(node.value.username)]),
                    html.td([], [node.id |> int.to_string |> html.text]),
                  ]),
                  ..acc
                ]
              }),
            ),
          ]),
        ]),
      ])
      |> element.to_document_string
      |> wisp.html_response(200)
  }
}
