import app
import clockwork
import envoy
import gleam/erlang/application
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/timestamp
import graph.{type Graph}
import graph_db.{UserData}
import grom
import grom/command
import grom/component/action_row
import grom/component/button
import grom/component/text_display
import grom/gateway
import grom/guild_member.{Member}
import grom/interaction.{type Interaction}
import grom/message
import grom/modification
import grom/user
import logging
import mist
import pairement
import simplifile
import wisp
import wisp/wisp_mist

type RequestHandlerContext {
  RequestHandlerContext(
    client: grom.Client,
    discord_public_key: String,
    interaction_handler_name: process.Name(
      factory_supervisor.Message(
        Interaction,
        process.Subject(InteractionHandlerMessage),
      ),
    ),
    master_password: String,
    graph_db_path: String,
    graph_db_temp_path: String,
  )
}

type InteractionHandlerContext {
  InteractionHandlerContext(
    client: grom.Client,
    admin_roles: List(String),
    graph_db_path: String,
    graph_db_temp_path: String,
    channel_id_path: String,
    pairement_manager: process.Subject(pairement.PairementMsg),
  )
}

type InteractionHandlerMessage {
  InteractionCreated(interaction: Interaction)
}

pub fn main() -> Nil {
  process.sleep_forever()
}

pub fn start(
  _app: atom.Atom,
  _type: application.StartType,
) -> Result(process.Pid, actor.StartError) {
  logging.configure()

  let assert Ok(db_path) = envoy.get("DB_PATH")
  let graph_db_path = db_path <> "/graph.csv"
  let graph_db_temp_path = db_path <> "/temp/graph.csv"
  let channel_id_path = db_path <> "/channel.txt"

  let assert Ok(token) = envoy.get("BOT_TOKEN")
  let assert Ok(discord_application_id) = envoy.get("DISCORD_APPLICATION_ID")
  let assert Ok(discord_public_key) = envoy.get("DISCORD_PUBLIC_KEY")
  let assert Ok(admin_roles) = envoy.get("ADMIN_ROLES")
  let assert Ok(master_password) = envoy.get("MASTER_PASSWORD")

  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")

  let client = grom.Client(token:)
  let cron =
    clockwork.Cron(
      minute: clockwork.exactly(0),
      hour: clockwork.exactly(12),
      day: clockwork.every_time(),
      month: clockwork.every_time(),
      weekday: clockwork.exactly(1),
    )

  let assert Ok(channel_id) =
    simplifile.read(channel_id_path)
    |> result.replace_error(Nil)
    |> result.or(envoy.get("CHANNEL_ID"))

  let _ = simplifile.write(channel_id, to: channel_id_path)

  let interaction_handler_name = process.new_name("interaction_handler_factory")
  let pairement_name = process.new_name("pairement")

  let global_commands = [
    command.CreateGlobalSlash(
      command.CreateGlobalSlashCommand(
        ..command.new_create_global_slash_command(
          named: "register",
          description: "Registre-se ou saia da lista de pareamento quinzenal",
        ),
        parameters: Some([
          command.SubCommandParameter(command.new_parameter_sub_command(
            "entrar",
            "Entre na lista",
          )),
          command.SubCommandParameter(command.new_parameter_sub_command(
            "sair",
            "Saia na lista",
          )),
        ]),
      ),
    ),
    command.CreateGlobalSlash(
      command.CreateGlobalSlashCommand(
        ..command.new_create_global_slash_command(
          named: "manage",
          description: "Comandos de administração do sistema de pareamento",
        ),
        parameters: Some([
          command.SubCommandParameter(command.new_parameter_sub_command(
            "listar-usuarios",
            "Lista todos os usuários na lista de pareamento",
          )),
          command.SubCommandParameter(command.new_parameter_sub_command(
            "limpar-lista",
            "Limpa a lista de pareamento",
          )),
          command.SubCommandParameter(
            command.ParameterSubCommand(
              ..command.new_parameter_sub_command(
                "adicionar-usuario",
                "Adiciona um usuário na lista de pareamento",
              ),
              parameters: Some([
                command.UserParameter(
                  command.ParameterUser(
                    ..command.new_parameter_user(
                      "user",
                      "Usuário a ser adicionado",
                    ),
                    is_required: True,
                  ),
                ),
              ]),
            ),
          ),
          command.SubCommandParameter(
            command.ParameterSubCommand(
              ..command.new_parameter_sub_command(
                "remover-usuario",
                "Remove um usuário da lista de pareamento",
              ),
              parameters: Some([
                command.UserParameter(
                  command.ParameterUser(
                    ..command.new_parameter_user(
                      "user",
                      "Usuário a ser removido",
                    ),
                    is_required: True,
                  ),
                ),
              ]),
            ),
          ),
          command.SubCommandParameter(command.new_parameter_sub_command(
            "proximo-pareamento",
            "Retorna a data do próximo pareamento",
          )),
          command.SubCommandParameter(command.new_parameter_sub_command(
            "testar-pareamento",
            "Simula um pareamento",
          )),
          command.SubCommandParameter(command.new_parameter_sub_command(
            "fazer-pareamento",
            "Roda o pareamento",
          )),
          command.SubCommandParameter(
            command.ParameterSubCommand(
              ..command.new_parameter_sub_command(
                "definir-canal",
                "Define o canal a ser postado os pareamentos",
              ),
              parameters: Some([
                command.ChannelParameter(
                  command.ParameterChannel(
                    ..command.new_parameter_channel(
                      "canal",
                      "Canal onde os pareamentos serão postados",
                    ),
                    is_required: True,
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    ),
  ]

  let assert Ok(_) =
    command.bulk_overwrite_global(
      client,
      of: discord_application_id,
      new: global_commands,
    )
  logging.log(
    logging.Info,
    "Overwrote the commands for " <> discord_application_id,
  )

  let pairement_manager =
    supervision.worker(fn() {
      pairement.new(client, cron, channel_id, graph_db_path, graph_db_temp_path)
      |> actor.named(pairement_name)
      |> actor.start()
    })

  let interaction_handler_factory =
    factory_supervisor.worker_child(start_interaction_handler(
      InteractionHandlerContext(
        client,
        string.split(admin_roles, on: ","),
        graph_db_path,
        graph_db_temp_path,
        channel_id_path,
        process.named_subject(pairement_name),
      ),
      _,
    ))
    |> factory_supervisor.named(interaction_handler_name)
    |> factory_supervisor.supervised

  let http_server =
    wisp_mist.handler(
      handle_request(
        _,
        RequestHandlerContext(
          client:,
          discord_public_key:,
          interaction_handler_name:,
          master_password:,
          graph_db_path:,
          graph_db_temp_path:,
        ),
      ),
      secret_key_base,
    )
    |> mist.new
    |> mist.port(2137)
    |> mist.bind("0.0.0.0")
    |> mist.supervised

  let supervisor_start_result =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(pairement_manager)
    |> static_supervisor.add(interaction_handler_factory)
    |> static_supervisor.add(http_server)
    |> static_supervisor.start

  case supervisor_start_result {
    Ok(actor.Started(pid:, ..)) -> {
      let _ = process.register(pid, process.new_name("one_on_one"))
      logging.log(logging.Info, "Started the gateway!")
    }
    Error(err) ->
      logging.log(
        logging.Error,
        "Couldn't start the gateway: " <> string.inspect(err),
      )
  }
  supervisor_start_result
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state) -> atom.Atom {
  atom.create("ok")
}

fn handle_request(
  req: Request(wisp.Connection),
  context: RequestHandlerContext,
) -> Response(wisp.Body) {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes

  case wisp.path_segments(req) {
    ["discord-interactions"] -> {
      use <- wisp.require_method(req, http.Post)
      use body <- wisp.require_string_body(req)

      interaction.handle_http_interaction_request(
        request.Request(..req, body:),
        context.discord_public_key,
        fn(interaction) { handle_interaction_request(context, interaction) },
      )
      |> response.map(wisp.Text)
    }
    _ ->
      app.handle_request(
        req,
        context.master_password,
        context.graph_db_path,
        context.graph_db_temp_path,
      )
  }
}

fn handle_interaction_request(
  context: RequestHandlerContext,
  interaction: Result(Interaction, interaction.HttpError),
) -> Nil {
  case interaction {
    Ok(interaction) ->
      handle_successful_interaction_request(context, interaction)
    Error(interaction.CouldNotParseInteraction(_)) ->
      logging.log(logging.Warning, "Could not parse interaction")
    Error(interaction.CouldNotValidateSecurityHeaders(_)) ->
      logging.log(logging.Warning, "Could not validate security headers")
  }
}

fn handle_successful_interaction_request(
  context: RequestHandlerContext,
  interaction: Interaction,
) -> Nil {
  let factory = factory_supervisor.get_by_name(context.interaction_handler_name)

  let start_result =
    factory
    |> factory_supervisor.start_child(interaction)

  case start_result {
    Ok(_) -> logging.log(logging.Info, "Started interaction handler worker")
    Error(_) ->
      logging.log(logging.Warning, "Could not start interaction handler worker")
  }
}

fn start_interaction_handler(
  context: InteractionHandlerContext,
  interaction: Interaction,
) -> Result(
  actor.Started(process.Subject(InteractionHandlerMessage)),
  actor.StartError,
) {
  actor.new_with_initialiser(4000, fn(subject) {
    // Every actor has an associated selector.
    // We must select our provided subject if we want to send messages to it.
    let selector =
      process.new_selector()
      |> process.select(subject)

    // Let's send a message on actor start-up.
    process.send(subject, InteractionCreated(interaction))

    actor.initialised(context)
    |> actor.returning(subject)
    |> actor.selecting(selector)
    |> Ok
  })
  |> actor.on_message(handle_interaction_handler_message)
  |> actor.start
}

fn handle_interaction_handler_message(
  context: InteractionHandlerContext,
  message: InteractionHandlerMessage,
) -> actor.Next(InteractionHandlerContext, a) {
  // We only deal with one type of message here,
  // but the case statement exists for future-proofing.
  case message {
    InteractionCreated(interaction) -> handle_interaction(context, interaction)
  }
}

// Finally, we get to handle our interaction.
fn handle_interaction(
  context: InteractionHandlerContext,
  interaction: Interaction,
) -> actor.Next(InteractionHandlerContext, a) {
  case interaction.data {
    interaction.CommandExecuted(command) ->
      on_command_executed(context, interaction, command)
    interaction.MessageComponentExecuted(message) ->
      on_message_component_executed(context, interaction, message)
    _ -> Nil
  }

  actor.stop()
}

fn on_guild_member_leave(
  context: InteractionHandlerContext,
  event: gateway.GuildMemberDeletedMessage,
) -> Nil {
  case int.parse(event.user.id) {
    Ok(id) -> {
      use graph <- load_graph(context.graph_db_path)
      case
        graph_db.save_graph(
          graph.remove_node(graph, id),
          context.graph_db_path,
          context.graph_db_temp_path,
        )
      {
        Ok(_) -> Nil
        Error(_) -> logging.log(logging.Error, "Couldn't save graph")
      }
    }
    Error(_) -> Nil
  }
}

fn on_command_executed(
  context: InteractionHandlerContext,
  interaction: Interaction,
  command: interaction.CommandExecution,
) {
  case command {
    interaction.SlashCommandExecuted(command) ->
      on_slash_command_executed(context, interaction, command)
    _ -> Nil
  }
}

fn on_message_component_executed(
  context: InteractionHandlerContext,
  interaction: Interaction,
  message: interaction.MessageComponentExecution,
) -> Nil {
  case message {
    interaction.ButtonExecuted(interaction.ButtonExecution(
      custom_id: "cancel-erase-list",
      ..,
    )) -> {
      let response =
        interaction.RespondWithUpdateMessage(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            components: Some([
              message.TextDisplay(text_display.new(
                ":white_check_mark: Apagamento cancelado.",
              )),
            ]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    interaction.ButtonExecuted(interaction.ButtonExecution(
      custom_id: "confirm-erase-list",
      ..,
    )) -> {
      let message = case
        graph_db.save_graph(
          graph.new(),
          context.graph_db_path,
          context.graph_db_temp_path,
        )
      {
        Ok(_) -> ":white_check_mark: Lista limpada com sucesso."
        Error(_) -> {
          logging.log(logging.Error, "Couldn't save graph")
          ":x: Ocorreu um erro interno."
        }
      }

      let response =
        interaction.RespondWithUpdateMessage(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            components: Some([
              message.TextDisplay(text_display.new(message)),
            ]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    _ -> Nil
  }
}

fn on_slash_command_executed(
  context: InteractionHandlerContext,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  case command.name {
    "register" -> on_register_command(context, interaction, command)
    "manage" -> on_manage_command(context, interaction, command)
    _ -> Nil
  }
}

fn on_register_command(
  context: InteractionHandlerContext,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  use _, member, user <- get_guild_invokation(interaction.invokement_info)
  case command.options {
    [interaction.SubCommandSlashCommandOption(name: "entrar", ..)] -> {
      use graph <- load_graph(context.graph_db_path)

      let user_connections = case int.parse(user.id) {
        Ok(id) ->
          graph.insert_node(
            graph,
            graph.Node(
              id,
              UserData(username: option.unwrap(member.nick, user.username)),
            ),
          )
          |> list.fold(graph.nodes(graph), _, fn(acc, node) {
            graph.insert_undirected_edge(acc, Nil, node.id, id)
          })
        Error(_) -> graph
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          context.graph_db_path,
          context.graph_db_temp_path,
        )
      {
        Ok(_) -> ":white_check_mark: Você foi registrado na lista!"
        Error(_) -> {
          logging.log(logging.Error, "Couldn't save graph")
          ":x: Ocorreu um erro interno."
        }
      }

      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(message),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client |> interaction.respond(to: interaction, using: response)

      Nil
    }
    [interaction.SubCommandSlashCommandOption(name: "sair", ..)] -> {
      use graph <- load_graph(context.graph_db_path)

      let user_connections = case int.parse(user.id) {
        Ok(id) -> graph.remove_node(graph, id)
        Error(_) -> graph
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          context.graph_db_path,
          context.graph_db_temp_path,
        )
      {
        Ok(_) -> ":wave: Você foi removido da lista."
        Error(_) -> {
          logging.log(logging.Error, "Couldn't save graph")
          ":x: Ocorreu um erro interno."
        }
      }

      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(message),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    _ -> Nil
  }
}

fn on_manage_command(
  context: InteractionHandlerContext,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) -> Nil {
  use guild_id, member, _ <- get_guild_invokation(interaction.invokement_info)
  use <- check_user_is_privileged(context, member, interaction)
  case command.options {
    [interaction.SubCommandSlashCommandOption(name: "listar-usuarios", ..)] -> {
      use graph <- load_graph(context.graph_db_path)

      let message =
        list.fold(
          graph.nodes(graph),
          "Aqui estão os usuários na lista:",
          fn(acc, user) { acc <> "\n" <> "<@" <> int.to_string(user.id) <> ">" },
        )
      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(message),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    [interaction.SubCommandSlashCommandOption(name: "limpar-lista", ..)] -> {
      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            flags: Some([
              interaction.EphemeralResponseMessage,
              interaction.ResponseMessageWithComponentsV2,
            ]),
            components: Some([
              message.TextDisplay(text_display.new(
                "Você está prestes a apagar a lista de pareamento. Deseja prosseguir?",
              )),
              message.ActionRow(
                action_row.new([
                  action_row.Button(button.Regular(
                    id: None,
                    is_disabled: False,
                    style: button.Secondary,
                    label: Some("Cancelar"),
                    emoji: None,
                    custom_id: "cancel-erase-list",
                  )),
                  action_row.Button(button.Regular(
                    id: None,
                    is_disabled: False,
                    style: button.Danger,
                    label: Some("Prosseguir"),
                    emoji: None,
                    custom_id: "confirm-erase-list",
                  )),
                ]),
              ),
            ]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)
      Nil
    }
    [
      interaction.SubCommandSlashCommandOption(
        name: "adicionar-usuario",
        options: [
          interaction.UserSlashCommandOption(name: "user", user_id:, ..),
        ],
      ),
    ] -> {
      use graph <- load_graph(context.graph_db_path)

      case guild_member.get(context.client, guild_id, user_id) {
        Error(_) | Ok(Member(user: option.None, ..)) ->
          logging.log(logging.Error, "Couldn't get user")
        Ok(Member(user: option.Some(user), ..)) -> {
          let user_connections = case int.parse(user_id) {
            Ok(id) ->
              graph.insert_node(
                graph,
                graph.Node(
                  id,
                  UserData(option.unwrap(member.nick, user.username)),
                ),
              )
              |> list.fold(graph.nodes(graph), _, fn(acc, node) {
                graph.insert_undirected_edge(acc, Nil, node.id, id)
              })
            Error(_) -> graph
          }

          let message = case
            graph_db.save_graph(
              user_connections,
              context.graph_db_path,
              context.graph_db_temp_path,
            )
          {
            Ok(_) -> ":white_check_mark: Usuário adicionado com sucesso."
            Error(_) -> {
              logging.log(logging.Error, "Couldn't save graph")
              ":x: Ocorreu um erro interno."
            }
          }
          let response =
            interaction.RespondWithChannelMessageWithSource(
              interaction.ResponseMessage(
                ..interaction.new_response_message(),
                content: Some(message),
                flags: Some([interaction.EphemeralResponseMessage]),
              ),
            )

          let _response_result =
            context.client
            |> interaction.respond(to: interaction, using: response)

          Nil
        }
      }
    }
    [
      interaction.SubCommandSlashCommandOption(
        name: "remover-usuario",
        options: [
          interaction.UserSlashCommandOption(name: "user", user_id:, ..),
        ],
      ),
    ] -> {
      use graph <- load_graph(context.graph_db_path)

      let user_connections = case int.parse(user_id) {
        Ok(id) -> graph.remove_node(graph, id)
        Error(_) -> graph
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          context.graph_db_path,
          context.graph_db_temp_path,
        )
      {
        Ok(_) -> ":white_check_mark: Usuário removido com sucesso."
        Error(_) -> {
          logging.log(logging.Error, "Couldn't save graph")
          ":x: Ocorreu um erro interno."
        }
      }
      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(message),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    [interaction.SubCommandSlashCommandOption(name: "proximo-pareamento", ..)] -> {
      let next_occurrence =
        process.call(
          context.pairement_manager,
          3000,
          pairement.GetNextPairement,
        )
      let #(unix_seconds, _) =
        timestamp.to_unix_seconds_and_nanoseconds(next_occurrence)
      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some("<t:" <> int.to_string(unix_seconds) <> ":f>"),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)
      Nil
    }
    [interaction.SubCommandSlashCommandOption(name: "testar-pareamento", ..)] -> {
      let response =
        interaction.RespondWithDeferredChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )
      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      let msg =
        process.call(
          context.pairement_manager,
          3000,
          pairement.SimulatePairement,
        )

      let response =
        interaction.ModifyOriginalResponse(
          ..interaction.new_modify_original_response(),
          content: modification.New(msg),
        )

      let _response_result =
        context.client
        |> interaction.modify_original_response(
          of: interaction,
          using: response,
        )

      Nil
    }
    [interaction.SubCommandSlashCommandOption(name: "fazer-pareamento", ..)] -> {
      let response =
        interaction.RespondWithDeferredChannelMessageWithSource(
          interaction.new_response_message(),
        )
      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      let msg =
        process.call(context.pairement_manager, 3000, pairement.RunPairementMsg)

      let response =
        interaction.ModifyOriginalResponse(
          ..interaction.new_modify_original_response(),
          content: modification.New(msg),
        )

      let _response_result =
        context.client
        |> interaction.modify_original_response(
          of: interaction,
          using: response,
        )

      Nil
    }
    [
      interaction.SubCommandSlashCommandOption(
        name: "definir-canal",
        options: [
          interaction.ChannelSlashCommandOption(name: "canal", channel_id:, ..),
        ],
      ),
    ] -> {
      let message = case
        simplifile.write(to: context.channel_id_path, contents: channel_id)
      {
        Ok(_) -> {
          process.send(
            context.pairement_manager,
            pairement.SetChannelId(channel_id:),
          )
          ":white_check_mark: Canal alterado com sucesso."
        }
        Error(_) -> {
          logging.log(logging.Error, "Couldn't save channel id")
          ":x: Ocorreu um erro interno."
        }
      }

      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(message),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)

      Nil
    }
    _ -> Nil
  }
}

fn get_guild_invokation(
  invokement_info: interaction.InvokementInfo,
  fun: fn(String, guild_member.GuildMember, user.User) -> Nil,
) -> Nil {
  case invokement_info {
    interaction.InvokedInGuild(
      guild_id:,
      member: Member(user: Some(user), ..) as member,
      ..,
    ) -> fun(guild_id, member, user)
    _ -> Nil
  }
}

fn check_user_is_privileged(
  context: InteractionHandlerContext,
  member: guild_member.GuildMember,
  interaction: Interaction,
  fun: fn() -> Nil,
) -> Nil {
  case
    list.fold(context.admin_roles, False, fn(acc, role) {
      acc || list.contains(member.roles, role)
    })
  {
    False -> {
      let response =
        interaction.RespondWithChannelMessageWithSource(
          interaction.ResponseMessage(
            ..interaction.new_response_message(),
            content: Some(":x: Você não tem permissão para usar este comando."),
            flags: Some([interaction.EphemeralResponseMessage]),
          ),
        )

      let _response_result =
        context.client
        |> interaction.respond(to: interaction, using: response)
      Nil
    }
    True -> fun()
  }
}

fn load_graph(
  graph_db_path: String,
  fun: fn(Graph(graph.Undirected, graph_db.UserData, Nil)) -> Nil,
) -> Nil {
  case graph_db.load_graph(graph_db_path) {
    Ok(graph) -> fun(graph)
    Error(_) -> logging.log(logging.Error, "Couldn't load graph")
  }
}
