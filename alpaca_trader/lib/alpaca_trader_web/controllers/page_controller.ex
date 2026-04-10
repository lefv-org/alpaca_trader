defmodule AlpacaTraderWeb.PageController do
  use AlpacaTraderWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
