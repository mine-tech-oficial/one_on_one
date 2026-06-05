import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import graph
import graph_db
import lustre/attribute
import lustre/element
import lustre/element/html
import wisp

pub fn handle_request(
  req: wisp.Request,
  master_password: String,
  graph_db_path: String,
  graph_db_temp_path: String,
) -> wisp.Response {
  case wisp.path_segments(req) {
    ["authenticate"] -> authenticate(req, master_password)
    ["dashboard"] -> serve_dashboard(req, graph_db_path)
    ["delete"] -> delete_user(req, graph_db_path, graph_db_temp_path)
    _ -> wisp.not_found()
  }
}

fn authenticate(req: wisp.Request, master_password: String) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use formdata <- wisp.require_form(req)

  case formdata.values {
    [#("password", password), ..] ->
      case password == master_password {
        True ->
          wisp.redirect("/dashboard")
          |> wisp.set_cookie(
            req,
            name: "session",
            value: crypto.strong_random_bytes(32)
              |> bit_array.base64_encode(True),
            security: wisp.Signed,
            max_age: 60 * 60 * 24 * 14,
          )
        False -> wisp.redirect("/dashboard")
      }

    _ -> wisp.unprocessable_content()
  }
}

fn serve_dashboard(req: wisp.Request, graph_db_path: String) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)

  let is_authenticated = wisp.get_cookie(req, "session", wisp.Signed)

  case graph_db.load_graph(graph_db_path) {
    Error(_) -> wisp.internal_server_error()
    Ok(graph) ->
      html.html([attribute.lang("pt")], [
        html.head([], [
          html.meta([attribute.charset("utf-8")]),
        ]),
        html.body([], [
          case is_authenticated {
            Ok(_) -> element.none()
            Error(_) ->
              html.form(
                [attribute.action("/authenticate"), attribute.method("post")],
                [
                  html.input([
                    attribute.type_("password"),
                    attribute.name("password"),
                  ]),
                  html.button([], [html.text("Authenticate")]),
                ],
              )
          },
          html.table([], [
            html.thead([], [
              html.tr([], [
                html.th([], [html.text("Nome do Aluno")]),
                html.td([], [html.text("ID do Discord")]),
                case is_authenticated {
                  Ok(_) -> html.td([], [html.text("Remover Aluno")])
                  Error(_) -> element.none()
                },
              ]),
            ]),
            html.tbody(
              [],
              list.map(graph.nodes(graph), fn(node) {
                html.tr([], [
                  html.th([], [html.text(node.value.username)]),
                  html.td([], [node.id |> int.to_string |> html.text]),
                  case is_authenticated {
                    Ok(_) ->
                      html.td([], [
                        html.button(
                          [
                            attribute.command("show-modal"),
                            attribute.commandfor(int.to_string(node.id)),
                          ],
                          [html.text("Remover Aluno")],
                        ),
                      ])
                    Error(_) -> element.none()
                  },
                ])
              }),
            ),
          ]),
        ]),
        ..list.map(graph.nodes(graph), fn(node) {
          html.dialog([attribute.id(int.to_string(node.id))], [
            html.form([attribute.action("/delete"), attribute.method("post")], [
              html.h2([], [
                html.text(
                  "Deseja remover " <> node.value.username <> " da lista?",
                ),
              ]),
              html.input([
                attribute.hidden(True),
                attribute.name("user_id"),
                attribute.value(int.to_string(node.id)),
              ]),
              html.button([attribute.formmethod("dialog")], [
                html.text("Cancelar"),
              ]),
              html.button([], [html.text("Remover")]),
            ]),
          ])
        })
      ])
      |> element.to_document_string
      |> wisp.html_response(200)
  }
}

fn delete_user(
  req: wisp.Request,
  graph_db_path: String,
  graph_db_temp_path: String,
) -> wisp.Response {
  use <- require_authentication(req)
  use <- wisp.require_method(req, http.Post)
  use formdata <- wisp.require_form(req)

  case formdata.values {
    [#("user_id", user_id), ..] -> {
      case int.parse(user_id) {
        Ok(user_id) ->
          case graph_db.load_graph(graph_db_path) |> result.replace_error(Nil) {
            Ok(graph) ->
              case
                graph_db.save_graph(
                  graph.remove_node(graph, user_id),
                  graph_db_path,
                  graph_db_temp_path,
                )
              {
                Ok(_) -> wisp.redirect("/dashboard")
                Error(_) -> wisp.internal_server_error()
              }
            Error(_) -> wisp.internal_server_error()
          }
        Error(_) -> wisp.unprocessable_content()
      }
    }
    _ -> wisp.unprocessable_content()
  }
}

fn require_authentication(
  req: wisp.Request,
  fun: fn() -> wisp.Response,
) -> wisp.Response {
  case wisp.get_cookie(req, "session", wisp.Signed) {
    Ok(_) -> fun()
    Error(_) -> wisp.response(403)
  }
}
