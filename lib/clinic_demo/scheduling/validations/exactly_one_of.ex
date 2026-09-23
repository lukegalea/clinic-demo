defmodule ClinicDemo.Scheduling.Validations.ExactlyOneOf do
  @moduledoc """
  Of a set of action arguments, exactly one must be supplied.

  Booking names its patient two ways — an existing `patient_id`, or a
  `patient` map to register on the spot — and the two are mutually
  exclusive by contract, not by luck. The `where: present(...)` guards on
  the manage_relationship changes decide which one *runs*; this validation
  is what makes supplying both (or neither) a refusal with a message that
  says so, instead of whichever write happened to land last.
  """

  use Ash.Resource.Validation

  alias Ash.Changeset

  @impl true
  def init(opts) do
    if is_list(opts[:arguments]) and opts[:arguments] != [] do
      {:ok, [arguments: List.wrap(opts[:arguments])]}
    else
      {:error, "`:arguments` must be a non-empty list of argument names"}
    end
  end

  @impl true
  def describe(opts) do
    [
      message: "supply exactly one of %{arguments}",
      vars: [arguments: names(opts)]
    ]
  end

  @impl true
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  def validate(changeset, opts, _context) do
    supplied = Enum.filter(opts[:arguments], &supplied?(changeset, &1))

    case length(supplied) do
      1 ->
        :ok

      0 ->
        {:error,
         field: :patient,
         message: "supply exactly one of %{arguments}",
         vars: [arguments: names(opts)]}

      _ ->
        {:error,
         field: :patient,
         message: "%{arguments} are mutually exclusive — supply exactly one",
         vars: [arguments: names(opts)]}
    end
  end

  defp supplied?(changeset, argument) do
    case Changeset.fetch_argument(changeset, argument) do
      {:ok, value} -> not blank?(value)
      :error -> false
    end
  end

  # A form submission carries shapes Ash would treat as "nothing here": an
  # empty map for a nested create, an empty list, an empty string, nil.
  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(map) when map == %{}, do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp names(opts), do: Enum.map_join(opts[:arguments], ", ", &to_string/1)
end
