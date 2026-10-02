defmodule ClinicDemo.EvalSets.Store do
  @moduledoc """
  Loads a labelled eval set (JSONL of label rows) into the pairs the
  agreement module consumes, and owns the store conventions that make that
  mechanical:

    * **Second-labeller identity is first-class.** Every row may carry
      `second_labeller`; when the field is absent the loader falls back to
      the recorded identity of this repo's only set so far (spike-0's blind
      second labelling, S1-21: the ora-4 agent, accepted as second labeller
      of record per the owner's 2026-10-02 sweep). New sets write the field
      explicitly — see `priv/fixtures/system_one/README.md`.
    * **Two label layers.** The *answer* layer is each question's own answer
      space (what `gold` is scored in). The *disposition* layer is design §1's
      five-value evidence-disposition vocabulary
      (`supports | contradicts | insufficient | not_applicable | wrong_scope`),
      derived mechanically for this repo's questions:
      a binary question's `true`/`false` is `supports`/`contradicts`;
      a choice question's option is `supports` and its
      `insufficient_information` option is `insufficient`. This is the mapping
      the spike-0 blind second labelling used
      (`priv/fixtures/system_one/spike0/blind-second-labels-notes.md`); a new
      question family that does not fit it extends the derivation explicitly,
      it is never guessed.

  Rows pair up by item id: `gold` is the first rater's label, `second_label`
  the second rater's. Rows whose `second_label` is still `nil` are reported
  as unpaired and excluded from agreement (the design drops or adjudicates
  them; nothing here decides which).
  """

  # The spike-0 record: "a second rater (an AI agent of this programme,
  # ora-4 — accepted as second labeller of record per the owner's
  # 2026-10-02 proceed-as-recommended sweep)". Absent-field fallback only;
  # new sets set the field.
  @default_second_labeller "ora-4"

  @set_root "priv/fixtures/system_one"

  @type item :: map()
  @type pair :: ClinicDemo.EvalSets.Agreement.pair()

  @doc "The fallback second-labeller identity for rows without `second_labeller`."
  def default_second_labeller, do: @default_second_labeller

  @doc """
  Set identity per design §1: `eval_set_hash` — SHA-256 over the canonical
  JSON of the set's rows. Canonical form (the design says "canonical JSON",
  no more): rows sorted by `id`, each row's keys sorted, no whitespace,
  joined by newlines — so row order and map key order never move the hash,
  and any label change (a filled `second_label`, an adjudication) does. The
  hex digest is what calibration runs record as the set they consumed.
  """
  def eval_set_hash(items) when is_list(items) do
    items
    |> Enum.sort_by(& &1["id"])
    |> Enum.map_join("\n", &canonical_json/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The directory holding set `name`'s files (items, splits companion)."
  def set_dir(name), do: Path.join([File.cwd!(), @set_root, name])

  # Minimal canonical JSON: sorted object keys, no whitespace. Rows carry
  # string keys, integers, booleans, nulls and strings only; the canonical
  # form leans on JSON.encode! for leaf encoding.
  defp canonical_json(%{} = value) do
    value
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(",", fn {k, v} -> JSON.encode!(to_string(k)) <> ":" <> canonical_json(v) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(values) when is_list(values),
    do: "[" <> Enum.map_join(values, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: JSON.encode!(value)

  @doc """
  Loads set `name` from `priv/fixtures/system_one/<name>/items.jsonl`, or an
  explicit path to a `.jsonl`. Returns the items plus provenance.
  """
  @spec load(String.t()) :: %{name: String.t(), path: String.t(), items: [item()]}
  def load(name_or_path) do
    path = path_for(name_or_path)

    items =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    %{name: name_from(name_or_path), path: path, items: items}
  end

  @doc "The first rater's identity on a row (`labeller`)."
  def first_labeller(item), do: Map.get(item, "labeller")

  @doc "The second rater's identity on a row, with the recorded store default."
  def second_labeller(item) do
    case Map.get(item, "second_labeller") do
      nil -> @default_second_labeller
      "" -> @default_second_labeller
      identity -> identity
    end
  end

  @doc "Ids of rows whose blind second label has not been filled in."
  def unpaired(items) do
    for item <- items, is_nil(Map.get(item, "second_label")), do: item["id"]
  end

  @doc """
  Answer-layer pairs for one `family` (a `question` value), in file order.
  Labels normalise to strings so class keys are uniform across the
  boolean noul answers and the choice answers.
  """
  @spec answer_pairs([item()], String.t()) :: [pair()]
  def answer_pairs(items, family) do
    items
    |> Enum.filter(&(&1["question"] == family))
    |> Enum.map(&{normalise(&1["gold"]), normalise(&1["second_label"])})
  end

  @doc "All answer-layer pairs, families pooled."
  @spec answer_pairs([item()]) :: [pair()]
  def answer_pairs(items),
    do: Enum.map(items, &{normalise(&1["gold"]), normalise(&1["second_label"])})

  @doc """
  Disposition-layer pairs (design §1's vocabulary) for one family, derived
  from the answer layer by the documented mapping — never guessed.
  """
  @spec disposition_pairs([item()], String.t()) :: [pair()]
  def disposition_pairs(items, family) do
    items
    |> Enum.filter(&(&1["question"] == family))
    |> Enum.map(&{disposition(&1["gold"]), disposition(&1["second_label"])})
  end

  @doc "All disposition-layer pairs, families pooled."
  @spec disposition_pairs([item()]) :: [pair()]
  def disposition_pairs(items),
    do: Enum.map(items, &{disposition(&1["gold"]), disposition(&1["second_label"])})

  @doc "The families (question values) in a set, in first-seen order."
  @spec families([item()]) :: [String.t()]
  def families(items) do
    items
    |> Enum.map(& &1["question"])
    |> Enum.uniq()
  end

  @doc """
  The disposition value of an answer label, per the store's documented
  mapping: `insufficient_information` → `insufficient`; a binary question's
  `true`/`false` → `supports`/`contradicts`; any other choice option →
  `supports`.
  """
  def disposition("insufficient_information"), do: "insufficient"
  def disposition(true), do: "supports"
  def disposition(false), do: "contradicts"
  def disposition("true"), do: "supports"
  def disposition("false"), do: "contradicts"
  def disposition(option) when is_binary(option), do: "supports"

  # --- internals ------------------------------------------------------------

  defp path_for("priv/" <> _ = path), do: Path.expand(path)

  defp path_for(name) do
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]*\z/, name) do
      raise ArgumentError, "eval set names are lower-case [a-z0-9_.-], got #{inspect(name)}"
    end

    path = Path.join([File.cwd!(), @set_root, name, "items.jsonl"])

    unless File.exists?(path) do
      raise ArgumentError, "no eval set #{inspect(name)} at #{path}"
    end

    path
  end

  defp name_from(name), do: name |> Path.basename() |> String.replace_suffix(".jsonl", "")

  defp normalise(nil), do: nil
  defp normalise(value) when is_boolean(value), do: Atom.to_string(value)
  defp normalise(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp normalise(value), do: value
end
