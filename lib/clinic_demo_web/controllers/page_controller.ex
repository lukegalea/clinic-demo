defmodule ClinicDemoWeb.PageController do
  use ClinicDemoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def operator(conn, _params) do
    render(conn, :operator)
  end
end
