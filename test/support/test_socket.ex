defmodule LoggerIntuitivoBackend.TestSocket do
  @moduledoc false
  # Mock Socket for tests. Set the agent with:
  #   Application.put_env(:logger_intuitivo_backend, :test_agent, agent)

  def send_log({msg, _id}) do
    case Application.get_env(:logger_intuitivo_backend, :test_agent) do
      nil -> :ok
      agent -> Agent.update(agent, fn list -> [{:log, msg} | list] end)
    end
  end

  def send_system(msg) do
    case Application.get_env(:logger_intuitivo_backend, :test_agent) do
      nil -> :ok
      agent -> Agent.update(agent, fn list -> [{:system, msg} | list] end)
    end
  end
end
