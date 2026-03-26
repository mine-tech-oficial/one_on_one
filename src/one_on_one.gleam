import clockwork
import envoy
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp
import graph.{type Graph}
import graph_db
import grom
import grom/command
import grom/component/action_row
import grom/component/button
import grom/component/text_display
import grom/gateway
import grom/guild_member
import grom/interaction.{type Interaction}
import grom/message
import grom/modification
import grom/user
import logging
import pairement
import simplifile

type State {
  State(
    client: grom.Client,
    admin_roles: List(String),
    graph_db_path: String,
    graph_db_temp_path: String,
    channel_id_path: String,
    pairement_manager: process.Subject(pairement.PairementMsg),
    user_connections: Graph(graph.Undirected, Nil, Nil),
  )
}

pub fn main() -> Nil {
  logging.configure()

  let assert Ok(db_path) = envoy.get("DB_PATH")
  let graph_db_path = db_path <> "/graph.csv"
  let graph_db_temp_path = db_path <> "/temp/graph.csv"
  let channel_id_path = db_path <> "/channel.txt"

  let assert Ok(token) = envoy.get("BOT_TOKEN")
  let assert Ok(admin_roles) = envoy.get("ADMIN_ROLES")

  let client = grom.Client(token:)
  let cron =
    clockwork.Cron(
      minute: clockwork.exactly(0),
      hour: clockwork.exactly(12),
      day: clockwork.every_time(),
      month: clockwork.every_time(),
      weekday: clockwork.exactly(0),
    )

  let identify =
    client
    |> gateway.identify(intents: [])

  let assert Ok(channel_id) =
    simplifile.read(channel_id_path)
    |> result.replace_error(Nil)
    |> result.or(envoy.get("CHANNEL_ID"))

  let _ = simplifile.write(channel_id, to: channel_id_path)

  let assert Ok(data) = gateway.get_data(client)
  let graph = result.unwrap(graph_db.load_graph(graph_db_path), graph.new())

  let assert Ok(actor.Started(data: pairement_manager, ..)) =
    pairement.new(client, cron, channel_id, graph_db_path, graph_db_temp_path)
    |> actor.start()

  let gateway_start_result =
    gateway.new(
      State(
        client,
        string.split(admin_roles, on: ","),
        graph_db_path,
        graph_db_temp_path,
        channel_id_path,
        pairement_manager,
        graph,
      ),
      identify,
      data,
    )
    |> gateway.on_event(do: on_event)
    |> gateway.start

  case gateway_start_result {
    Ok(_) -> {
      logging.log(logging.Info, "Started the gateway!")
      process.sleep_forever()
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "Couldn't start the gateway: " <> string.inspect(err),
      )
    }
  }
}

fn on_event(state: State, event: gateway.Event) {
  case event {
    gateway.ErrorEvent(error) -> {
      logging.log(logging.Warning, string.inspect(error))
      gateway.continue(state)
    }
    gateway.AllShardsReadyEvent(ready) -> on_ready(state, ready)
    gateway.InteractionCreatedEvent(interaction) ->
      on_interaction_created(state, interaction)
    _ -> gateway.continue(state)
  }
}

fn on_ready(state: State, ready: gateway.AllShardsReadyMessage) {
  logging.log(logging.Info, "Ready!")

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
          named: "manage-pairs",
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

  let bulk_overwrite_result =
    state.client
    |> command.bulk_overwrite_global(
      of: ready.application.id,
      new: global_commands,
    )

  case bulk_overwrite_result {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "Overwrote the commands for " <> ready.application.id,
      )
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "Couldn't bulk overwrite global commands: " <> string.inspect(err),
      )
    }
  }

  gateway.continue(state)
}

fn on_interaction_created(state: State, interaction: Interaction) {
  case interaction.data {
    interaction.CommandExecuted(command) ->
      on_command_executed(state, interaction, command)
    interaction.MessageComponentExecuted(message) ->
      on_message_component_executed(state, interaction, message)
    _ -> gateway.continue(state)
  }
}

fn on_command_executed(
  state: State,
  interaction: Interaction,
  command: interaction.CommandExecution,
) {
  case command {
    interaction.SlashCommandExecuted(command) ->
      on_slash_command_executed(state, interaction, command)
    _ -> gateway.continue(state)
  }
}

fn on_message_component_executed(
  state: State,
  interaction: Interaction,
  message: interaction.MessageComponentExecution,
) -> gateway.Next(State) {
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(state)
    }
    interaction.ButtonExecuted(interaction.ButtonExecution(
      custom_id: "confirm-erase-list",
      ..,
    )) -> {
      let message = case
        graph_db.save_graph(
          graph.new(),
          state.graph_db_path,
          state.graph_db_temp_path,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(State(..state, user_connections: graph.new()))
    }
    _ -> gateway.continue(state)
  }
}

fn on_slash_command_executed(
  state: State,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  case command.name {
    "register" -> on_register_command(state, interaction, command)
    "manage-pairs" -> on_manage_command(state, interaction, command)
    _ -> gateway.continue(state)
  }
}

fn on_register_command(
  state: State,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  use _, user <- get_guild_invokation(state, interaction.invokement_info)
  case command.options {
    [interaction.SubCommandSlashCommandOption(name: "entrar", ..)] -> {
      let user_connections = case int.parse(user.id) {
        Ok(id) ->
          graph.insert_node(state.user_connections, graph.Node(id, Nil))
          |> list.fold(graph.nodes(state.user_connections), _, fn(acc, node) {
            graph.insert_undirected_edge(acc, Nil, node.id, id)
          })
        Error(_) -> state.user_connections
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          state.graph_db_path,
          state.graph_db_temp_path,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(State(..state, user_connections:))
    }
    [interaction.SubCommandSlashCommandOption(name: "sair", ..)] -> {
      let user_connections = case int.parse(user.id) {
        Ok(id) -> graph.remove_node(state.user_connections, id)
        Error(_) -> state.user_connections
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          state.graph_db_path,
          state.graph_db_temp_path,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(State(..state, user_connections:))
    }
    _ -> gateway.continue(state)
  }
}

fn on_manage_command(
  state: State,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) -> gateway.Next(State) {
  use member, _ <- get_guild_invokation(state, interaction.invokement_info)
  use <- check_user_is_privileged(state, member, interaction)
  case command.options {
    [interaction.SubCommandSlashCommandOption(name: "listar-usuarios", ..)] -> {
      let message =
        list.fold(
          graph.nodes(state.user_connections),
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
        state.client
        |> interaction.respond(to: interaction, using: response)
      gateway.continue(state)
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
        state.client
        |> interaction.respond(to: interaction, using: response)
      gateway.continue(state)
    }
    [
      interaction.SubCommandSlashCommandOption(
        name: "adicionar-usuario",
        options: [
          interaction.UserSlashCommandOption(name: "user", user_id:, ..),
        ],
      ),
    ] -> {
      let user_connections = case int.parse(user_id) {
        Ok(id) ->
          graph.insert_node(state.user_connections, graph.Node(id, Nil))
          |> list.fold(graph.nodes(state.user_connections), _, fn(acc, node) {
            graph.insert_undirected_edge(acc, Nil, node.id, id)
          })
        Error(_) -> state.user_connections
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          state.graph_db_path,
          state.graph_db_temp_path,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(State(..state, user_connections:))
    }
    [
      interaction.SubCommandSlashCommandOption(
        name: "remover-usuario",
        options: [
          interaction.UserSlashCommandOption(name: "user", user_id:, ..),
        ],
      ),
    ] -> {
      let user_connections = case int.parse(user_id) {
        Ok(id) -> graph.remove_node(state.user_connections, id)
        Error(_) -> state.user_connections
      }

      let message = case
        graph_db.save_graph(
          user_connections,
          state.graph_db_path,
          state.graph_db_temp_path,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(State(..state, user_connections:))
    }
    [interaction.SubCommandSlashCommandOption(name: "proximo-pareamento", ..)] -> {
      let next_occurrence =
        process.call(state.pairement_manager, 3000, pairement.GetNextPairement)
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
        state.client
        |> interaction.respond(to: interaction, using: response)
      gateway.continue(state)
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      let msg =
        process.call(state.pairement_manager, 3000, pairement.SimulatePairement)

      let response =
        interaction.ModifyOriginalResponse(
          ..interaction.new_modify_original_response(),
          content: modification.New(msg),
        )

      let _response_result =
        state.client
        |> interaction.modify_original_response(
          of: interaction,
          using: response,
        )

      gateway.continue(state)
    }
    [interaction.SubCommandSlashCommandOption(name: "fazer-pareamento", ..)] -> {
      let response =
        interaction.RespondWithDeferredChannelMessageWithSource(
          interaction.new_response_message(),
        )
      let _response_result =
        state.client
        |> interaction.respond(to: interaction, using: response)

      let msg =
        process.call(state.pairement_manager, 3000, pairement.RunPairementMsg)

      let response =
        interaction.ModifyOriginalResponse(
          ..interaction.new_modify_original_response(),
          content: modification.New(msg),
        )

      let _response_result =
        state.client
        |> interaction.modify_original_response(
          of: interaction,
          using: response,
        )

      gateway.continue(state)
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
        simplifile.write(to: state.channel_id_path, contents: channel_id)
      {
        Ok(_) -> {
          process.send(
            state.pairement_manager,
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
        state.client
        |> interaction.respond(to: interaction, using: response)

      gateway.continue(state)
    }
    _ -> gateway.continue(state)
  }
}

fn get_guild_invokation(
  state: State,
  invokement_info: interaction.InvokementInfo,
  f: fn(guild_member.GuildMember, user.User) -> gateway.Next(State),
) -> gateway.Next(State) {
  case invokement_info {
    interaction.InvokedInGuild(
      member: guild_member.Member(user: Some(user), ..) as member,
      ..,
    ) -> f(member, user)
    _ -> gateway.continue(state)
  }
}

fn check_user_is_privileged(
  state: State,
  member: guild_member.GuildMember,
  interaction: Interaction,
  f: fn() -> gateway.Next(State),
) -> gateway.Next(State) {
  case
    list.fold(state.admin_roles, False, fn(acc, role) {
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
        state.client
        |> interaction.respond(to: interaction, using: response)
      gateway.continue(state)
    }
    True -> f()
  }
}
