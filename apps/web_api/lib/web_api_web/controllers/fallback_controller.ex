defmodule WebApiWeb.FallbackController do
  use Phoenix.Controller
  require Logger

  alias WebApiWeb.ErrorView

  def call(conn, {:error, :no_chain_connected}) do
    Logger.error(fn -> "No connectivity to ex_testchain !" end)

    conn
    |> put_status(500)
    |> put_view(ErrorView)
    |> render("500.json", message: "No ex_testchain service connected. Please contact support !")
  end

  def call(conn, {:error, msg}) when is_binary(msg) do
    conn
    |> put_status(500)
    |> put_view(ErrorView)
    |> render("500.json", message: msg)
  end
end
