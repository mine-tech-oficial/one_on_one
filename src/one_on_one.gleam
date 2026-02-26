import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import gleam/string
import grom
import grom/command
import grom/gateway
import grom/gateway/intent
import grom/guild_member
import grom/interaction.{type Interaction}
import grom/user
import logging
import storail

type State {
  State(client: grom.Client, db: storail.Collection(User))
}

type User {
  User
}

fn user_to_json(user: User) -> json.Json {
  json.string("user")
}

fn user_decoder() -> decode.Decoder(User) {
  use variant <- decode.then(decode.string)
  case variant {
    "user" -> decode.success(User)
    _ -> decode.failure(User, "User")
  }
}

pub fn main() -> Nil {
  logging.configure()

  let assert Ok(token) = envoy.get("BOT_TOKEN")

  let client = grom.Client(token:)
  let db =
    storail.Collection(
      name: "users",
      to_json: user_to_json,
      decoder: user_decoder(),
      config: storail.Config("db"),
    )

  let identify =
    client
    |> gateway.identify(intents: [])

  let assert Ok(data) = gateway.get_data(client)

  let gateway_start_result =
    gateway.new(State(client, db), identify, data)
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
          command.TextParameter(
            command.ParameterText(
              ..command.new_parameter_text("action", "Ação a ser executada"),
              is_required: True,
              choices: Some([
                command.new_text_choice("entrar", "entrar"),
                command.new_text_choice("sair", "sair"),
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

fn on_slash_command_executed(
  state: State,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  case command.name {
    "register" -> on_register_command(state, interaction, command)
    _ -> gateway.continue(state)
  }
}

fn on_register_command(
  state: State,
  interaction: Interaction,
  command: interaction.SlashCommandExecution,
) {
  case interaction.invokement_info, command.options {
    interaction.InvokedInGuild(
      member: guild_member.Member(user: Some(user.User(id:, ..)), ..),
      ..,
    ),
      [
        interaction.StringSlashCommandOption(
          name: "action",
          value: "entrar",
          ..,
        ),
      ]
    -> {
      let message = case storail.write(storail.key(state.db, id), User) {
        Ok(_) -> ":white_check_mark: Você foi registrado na lista!"
        Error(_) -> ":x: Ocorreu um erro interno."
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
    interaction.InvokedInGuild(
      member: guild_member.Member(user: Some(user.User(id:, ..)), ..),
      ..,
    ),
      [interaction.StringSlashCommandOption(name: "action", value: "sair", ..)]
    -> {
      let message = case storail.delete(storail.key(state.db, id)) {
        Ok(_) -> ":wave: Você foi removido da lista."
        Error(_) -> ":x: Ocorreu um erro interno."
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
    _, _ -> gateway.continue(state)
  }
}
