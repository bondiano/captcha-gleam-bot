import dotenv_gleam
import envoy
import gleam/bool
import gleam/erlang/process
import gleam/option.{Some}
import logging
import mist
import wisp.{type Response}
import wisp/wisp_mist

import telega
import telega/adapters/wisp as telega_wisp
import telega/api as telega_api
import telega/bot.{type Context}
import telega/error as telega_error
import telega/model as telega_model
import telega/reply
import telega/update as telega_update

import session.{type CaptchaBotSession}

type BotContext =
  Context(CaptchaBotSession, BotError)

type BotError {
  TelegaBotError(telega_error.TelegaError)
}

fn middleware(req, bot, next) -> Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use <- telega_wisp.handle_bot(req, bot)
  use req <- wisp.handle_head(req)
  next(req)
}

fn handle_request(bot, req) {
  use req <- middleware(req, bot)

  case wisp.path_segments(req) {
    ["health"] -> wisp.ok()
    _ -> wisp.not_found()
  }
}

fn create_captcha() {
  let question = "What is the capital of France?"
  let answer = "Paris"

  #(question, answer)
}

fn verify_captcha(ctx: BotContext, update) {
  use <- telega.log_context(ctx, "verifying_captcha")
  case ctx.session {
    session.CaptchaBotSolvedSession -> Ok(ctx)
    session.CaptchaBotSolvingSession(answer) ->
      case update {
        telega_update.TextUpdate(chat_id:, text:, message:, ..) -> {
          use <- bool.lazy_guard(text == answer, fn() {
            bot.next_session(ctx, session.CaptchaBotSolvedSession)
          })

          use _ <- try(telega_api.delete_message(
            ctx.config.api_client,
            parameters: telega_model.DeleteMessageParameters(
              chat_id: telega_model.Int(chat_id),
              message_id: message.message_id,
            ),
          ))

          Ok(ctx)
        }

        _ -> Ok(ctx)
      }
    session.CaptchaBotNewSession -> {
      let #(question, answer) = create_captcha()
      use _ <- try(reply.with_text(
        ctx,
        "Please solve the captcha:\n" <> question,
      ))

      bot.next_session(ctx, session.CaptchaBotSolvingSession(answer))
    }
  }
}

fn build_bot() {
  let assert Ok(token) = envoy.get("BOT_TOKEN")
  let assert Ok(webhook_path) = envoy.get("WEBHOOK_PATH")
  let assert Ok(url) = envoy.get("SERVER_URL")
  let assert Ok(secret_token) = envoy.get("BOT_SECRET_TOKEN")

  telega.new(token:, url:, webhook_path:, secret_token: Some(secret_token))
  |> telega.set_drop_pending_updates(True)
  |> telega.handle_all(verify_captcha)
  |> session.attach()
  |> telega.init()
}

pub fn main() {
  dotenv_gleam.config()
  wisp.configure_logger()

  let assert Ok(bot) = build_bot()
  let secret_key_base = wisp.random_string(64)
  let assert Ok(_) =
    wisp_mist.handler(handle_request(bot, _), secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start_http

  logging.log(logging.Info, "Bot started")

  process.sleep_forever()
}

fn try(result, fun) {
  telega_error.try(result, TelegaBotError, fun)
}
